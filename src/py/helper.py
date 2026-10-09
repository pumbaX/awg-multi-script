"""Встроенный помощник awg2: разбор и атомарная правка конфигов, JSON Xray,
расчёты подсетей, разбор pcap. Вызывается как `py <команда> [аргументы]`.

Коды выхода: 0 — успех, 1 — ошибка (текст в stderr), 2 — не найдено,
3 — дубликат. Всё, что пишется в файлы, пишется через временный файл рядом
с целевым и os.replace: обрыв на середине не оставляет битый конфиг.
"""
import base64
import importlib
import json
import os
import re
import struct
import sys
import time
import urllib.parse


class _Lazy:
    """Модуль, который загружается при первом обращении: большинство команд
    его не трогает, а awg2 api зовёт помощник дважды на каждый вызов."""

    def __init__(self, name):
        self._name, self._mod = name, None

    def __getattr__(self, attr):
        if self._mod is None:
            self._mod = importlib.import_module(self._name)
        return getattr(self._mod, attr)


ipaddress = _Lazy("ipaddress")
random = _Lazy("random")
secrets = _Lazy("secrets")
shutil = _Lazy("shutil")
string = _Lazy("string")
tempfile = _Lazy("tempfile")


def die(msg, code=1):
    sys.stderr.write(msg.rstrip() + "\n")
    sys.exit(code)


def read(path):
    # surrogateescape: один не-UTF-8 байт в правленном руками конфиге иначе
    # останавливал все команды (peers, expire-check…), а байты так проходят
    # через чтение и запись без изменений.
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write_atomic(path, text, mode=0o600):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".awg2.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ════════════════════════ awg0.conf ════════════════════════
# Блок [Peer] может нести служебные комментарии «# ключ=значение»
# (mimicry, expires, orig_ips, note — последнюю пишет бот). Имя клиента —
# первый комментарий без «=»: валидатор имён этот знак не пропускает.

# Как парсер wireguard-tools: заголовок и ключи без учёта регистра, с
# пробелами по краям и комментарием «# …» в конце строки — такой пир живой
# для awg, значит и для нас.
PEER_SPLIT = re.compile(r"(?=^[ \t]*\[[ \t]*peer[ \t]*\][ \t]*(?:#.*)?$)", re.M | re.I)


def split_peers(text):
    parts = PEER_SPLIT.split(text)
    return parts[0], parts[1:]


def peer_name(block):
    lines = block.splitlines()
    # «[Peer] # alice» — имя в заголовке, как пишут руками и другие менеджеры
    m = re.match(r"^[ \t]*\[[ \t]*peer[ \t]*\][ \t]*#[ \t]*(.+?)[ \t]*$", lines[0] if lines else "", re.I)
    if m and "=" not in m.group(1):
        return m.group(1)
    for line in lines[1:]:
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m and "=" not in m.group(1):
            return m.group(1)
    return ""


def peer_field(block, key):
    m = re.search(r"^[ \t]*%s[ \t]*=[ \t]*([^#\r\n]*?)[ \t]*(?:#.*)?$" % re.escape(key), block, re.M | re.I)
    return m.group(1) if m else ""


def peer_meta(block, key):
    m = re.search(r"^#\s*%s=(.*?)\s*$" % re.escape(key), block, re.M)
    return m.group(1) if m else ""


def find_peer(peers, name=None, pubkey=None):
    for i, b in enumerate(peers):
        if pubkey is not None and peer_field(b, "PublicKey") == pubkey:
            return i
        if name is not None and peer_name(b) == name:
            return i
    return -1


def set_meta(block, key, value):
    block = re.sub(r"^#\s*%s=.*\n?" % re.escape(key), "", block, flags=re.M)
    if not value:
        return block
    lines = block.split("\n")
    # Метка встаёт сразу после имени, а без имени — после [Peer]
    at = 1
    for i, line in enumerate(lines[1:], 1):
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m and "=" not in m.group(1):
            at = i + 1
            break
    lines.insert(at, "# %s=%s" % (key, value))
    return "\n".join(lines)


def cmd_peers(conf):
    _, peers = split_peers(read(conf))
    for b in peers:
        pub = peer_field(b, "PublicKey")
        if not pub:
            continue
        print("\t".join([peer_name(b), pub, peer_field(b, "AllowedIPs"),
                         peer_meta(b, "expires"), peer_meta(b, "orig_ips"),
                         peer_meta(b, "mimicry"), peer_meta(b, "limit"), peer_meta(b, "blocked_by")]))


def cmd_meta_set(conf, name, key, value):
    head, peers = split_peers(read(conf))
    i = find_peer(peers, name=name)
    if i < 0:
        die("клиент %s не найден" % name, 2)
    peers[i] = set_meta(peers[i], key, value)
    write_atomic(conf, head + "".join(peers))


def cmd_peer_del(conf, pubkey):
    head, peers = split_peers(read(conf))
    i = find_peer(peers, pubkey=pubkey)
    if i < 0:
        die("пир не найден", 2)
    name = peer_name(peers[i])
    del peers[i]
    text = head + "".join(peers)
    write_atomic(conf, re.sub(r"\n{3,}", "\n\n", text))
    print(name)


def cmd_peer_rename(conf, pubkey, new):
    head, peers = split_peers(read(conf))
    i = find_peer(peers, pubkey=pubkey)
    if i < 0:
        die("пир не найден", 2)
    lines = peers[i].split("\n")
    for j, line in enumerate(lines[1:], 1):
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m and "=" not in m.group(1):
            lines[j] = "# " + new
            break
    else:
        lines.insert(1, "# " + new)
    peers[i] = "\n".join(lines)
    write_atomic(conf, head + "".join(peers))


def cmd_peers_clear(conf):
    head, _ = split_peers(read(conf))
    write_atomic(conf, head.rstrip("\n") + "\n")


AWG_PARAM_KEYS = ("Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4",
                  "HeaderProtectionKey", "ContentPaddingAddition", "RekeyAfterTime",
                  "RekeyTimeout", "RejectAfterTime", "KeepaliveTimeout",
                  "MaxHandshakeAttempts", "RandomTrailers", "DisableCookies")
PARAM_RE = re.compile(r"^(%s)\s*=" % "|".join(AWG_PARAM_KEYS))


def cmd_params_replace(path):
    """Заменить параметры AmneziaWG в [Interface] на строки из stdin.

    Ключи, адреса, I1-I5, DNS, MTU и секции [Peer] не трогаются: меняется
    только то, что обязано совпадать у сервера и всех клиентов.
    """
    params = [l for l in sys.stdin.read().splitlines() if l.strip()]
    if not params:
        die("пустой набор параметров")
    out, in_iface, done = [], False, False
    for line in read(path).split("\n"):
        if re.match(r"^\[Interface\]", line):
            in_iface = True
            out.append(line)
            continue
        if line.startswith("["):
            if in_iface and not done:
                if out and out[-1] == "":
                    out.pop()
                    out.extend(params)
                    out.append("")
                else:
                    out.extend(params)
                done = True
            in_iface = False
        if in_iface and PARAM_RE.match(line):
            if not done:
                out.extend(params)
                done = True
            continue
        out.append(line)
    if not done:
        out.extend(params)
    write_atomic(path, "\n".join(out))


# ── Правка параметров вручную ─────────────────────────────
# Пределы — те же, что соблюдает генератор (params.sh); здесь они проверяют
# то, что ввёл человек. Совпадать у сервера и клиентов обязаны S1-S4, H1-H4,
# HeaderProtectionKey и RandomTrailers; мусорные пакеты, ContentPaddingAddition
# и таймеры — нет (README amneziawg-go: «client-side»).
U32 = 0xFFFFFFFF
HP_MIN_S, S4_MAX, JC_MAX, S_GAP = 12, 32, 128, 10
MTU_OVERHEAD, MTU_SAFETY = 60, 24
BREAKING = ("S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "HeaderProtectionKey", "RandomTrailers")
EDIT_BASE = ("Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4")
EDIT_3X = ("ContentPaddingAddition", "RekeyAfterTime", "RekeyTimeout", "RejectAfterTime",
           "KeepaliveTimeout", "MaxHandshakeAttempts")
EDIT_31 = ("RandomTrailers", "DisableCookies")
SWITCHES = ("RandomTrailers", "DisableCookies")


def params_editable(proto):
    keys = list(EDIT_BASE)
    if proto.startswith("3"):
        keys += EDIT_3X
    if proto == "3.1":
        keys += EDIT_31
    return keys


def _prange(v):
    """«a» или «a-b» (a ≤ b ≤ 2^32-1) → (a, b); иначе None."""
    m = re.fullmatch(r"(\d{1,10})(?:-(\d{1,10}))?", v or "")
    if not m:
        return None
    a = int(m[1])
    b = int(m[2]) if m[2] else a
    return (a, b) if a <= b <= U32 else None


def _pnum(v):
    return int(v) if re.fullmatch(r"\d{1,10}", v or "") and int(v) <= U32 else None


def _params_norm(key, val):
    val = re.sub(r"\s+", "", val or "")
    if key in SWITCHES:
        low = val.lower()
        if low in ("on", "1", "yes", "true", "да", "вкл"):
            return "on"
        if low in ("off", "0", "no", "false", "нет", "выкл", ""):
            return "off"
    return val


def params_check(proto, mtu, old, edits):
    """old — {ключ: значение} из конфига, edits — [(ключ, значение)].
    → (ошибки, предупреждения, изменённые, новый словарь)."""
    errs, warns = [], []
    editable = params_editable(proto)
    by_low = {k.lower(): k for k in AWG_PARAM_KEYS}
    new = dict(old)
    for key, val in edits:
        k = by_low.get(key.strip().lower())
        if k is None:
            errs.append(f"{key}: нет такого параметра AmneziaWG")
        elif k == "HeaderProtectionKey":
            errs.append("HeaderProtectionKey меняется перегенерацией: Протокол → новые параметры")
        elif k not in editable:
            errs.append(f"{k}: параметр AWG 3.x, а сервер на {proto}")
        else:
            new[k] = _params_norm(k, val)
    for k in SWITCHES:
        if new.get(k) == "off":
            del new[k]
    changed = [k for k in AWG_PARAM_KEYS if old.get(k, "") != new.get(k, "")]
    ch = set(changed)
    is3 = proto.startswith("3")

    def num(k, lo, hi, what):
        v = _pnum(new.get(k, ""))
        if v is None or not lo <= v <= hi:
            errs.append(f"{k} = {new.get(k, '') or 'пусто'}: нужно {what}")
            return None
        return v

    jc = num("Jc", 0, JC_MAX, f"целое 0-{JC_MAX}")
    jmin = num("Jmin", 0, 1472, "целое 0-1472")
    jmax = num("Jmax", 0, 1472, "целое 0-1472 — больше не влезет в пакет 1500, а фрагменты заметны цензору")
    if jmin is not None and jmax is not None and jmin > jmax:
        errs.append(f"Jmin ({jmin}) больше Jmax ({jmax})")
    if jc is not None and "Jc" in ch and not 3 <= jc <= 12:
        warns.append(f"Jc = {jc}: рекомендуется 3-12" + (" — без мусорных пакетов" if jc == 0 else ""))

    # Рукопожатия с паддингом обязаны влезать в 1280 — минимальный MTU IPv6
    smin = HP_MIN_S if is3 else 0
    s = {}
    for k, base, hi in (("S1", 148, 1132), ("S2", 92, 1188), ("S3", 64, 1216), ("S4", 32, S4_MAX)):
        what = f"целое {smin}-{hi}" + (" (AWG 3.x требует ≥ 12)" if is3 else "") + (" — предел amneziawg-tools" if k == "S4" else "")
        s[k] = num(k, smin, hi, what)
    if None not in (s["S1"], s["S2"], s["S3"]):
        lens = {"S1": 148 + s["S1"], "S2": 92 + s["S2"], "S3": 64 + s["S3"]}
        names = {"S1": "инициации", "S2": "ответа", "S3": "cookie"}
        pairs = (("S1", "S2"), ("S1", "S3"), ("S2", "S3"))
        for a, b in pairs:
            d = abs(lens[a] - lens[b])
            if d == 0:
                errs.append(f"{a} и {b}: пакеты {names[a]} и {names[b]} выйдут одной длины ({lens[a]} Б) — "
                            "сервер не отличит их")
            elif d < S_GAP and ({a, b} & ch):
                warns.append(f"{a} и {b}: длины пакетов {names[a]} и {names[b]} почти совпадают "
                             f"({lens[a]} и {lens[b]} Б) — генератор разводит их на {S_GAP}+")

    h = {}
    for k in ("H1", "H2", "H3", "H4"):
        r = _prange(new.get(k, ""))
        if r is None:
            errs.append(f"{k} = {new.get(k, '') or 'пусто'}: нужно число или диапазон a-b (a ≤ b ≤ {U32})")
        else:
            h[k] = r
    keys = sorted(h)
    for i, a in enumerate(keys):
        for b in keys[i + 1:]:
            if h[a][0] <= h[b][1] and h[b][0] <= h[a][1]:
                errs.append(f"{a} и {b} пересекаются — сервер не отличит типы пакетов")
    if not is3:
        for k, (lo, hi) in h.items():
            if k not in ch:
                continue
            if lo <= 4:
                warns.append(f"{k}: задевает 1-4 — стандартные типы WireGuard, прямой признак для DPI")
            if hi > 0x7FFFFFFF:
                warns.append(f"{k}: выше 2147483647 — старый клиент AmneziaVPN для Windows не примет")
            if hi - lo < 1000:
                warns.append(f"{k}: узкий диапазон — заголовок почти постоянный, это подпись для DPI")

    cpa = 0
    if is3:
        for k in EDIT_3X:
            if k not in new:
                continue
            r = _prange(new[k])
            if r is None or r[0] < (0 if k == "ContentPaddingAddition" else 1):
                errs.append(f"{k} = {new[k] or 'пусто'}: нужно число или диапазон a-b"
                            + ("" if k == "ContentPaddingAddition" else ", от 1"))
            elif k == "ContentPaddingAddition":
                cpa = r[1]
        rat, rjt = _prange(new.get("RekeyAfterTime", "")), _prange(new.get("RejectAfterTime", ""))
        if rat and rjt and rjt[0] <= rat[1]:
            errs.append("RejectAfterTime должен быть целиком больше RekeyAfterTime — иначе сессия умрёт "
                        "раньше, чем переустановится")
        rkt = _prange(new.get("RekeyTimeout", ""))
        if rkt and rkt[0] < 5 and "RekeyTimeout" in ch:
            warns.append("RekeyTimeout меньше 5 с — лишние повторы рукопожатия")
        for k in SWITCHES:
            if k in new and new[k] != "on":
                errs.append(f"{k}: только on или off")

    # Запас до пути 1500: тот же расчёт, что у генератора (_check_mtu_headroom)
    if str(mtu).isdigit() and s.get("S4") is not None and ({"S4", "ContentPaddingAddition"} & ch):
        outer = int(mtu) + MTU_OVERHEAD + s["S4"] + cpa
        if outer > 1500 - MTU_SAFETY:
            warns.append(f"MTU {mtu}: внешний пакет до {outer} Б — не остаётся запаса до 1500; "
                         "уменьши S4" + (" или ContentPaddingAddition" if is3 else ""))
    return errs, warns, changed, new


def cmd_params_check(proto, mtu, *edits):
    """stdin — параметры сервера («Ключ = значение»), аргументы — правки
    «Ключ=значение». Вывод построчно: K ключ значение (редактируемые, после
    правок), E ошибка, W предупреждение, C изменённый ключ, B изменённый ключ,
    который обязан совпадать у клиентов, P строка нового блока параметров."""
    old = {}
    for line in sys.stdin.read().splitlines():
        m = re.match(r"^(\w+)\s*=\s*(.*?)\s*$", line)
        if m and m[1] in AWG_PARAM_KEYS:
            old[m[1]] = m[2]
    pairs = []
    for e in edits:
        if "=" not in e:
            die(f"правка «{e}»: нужно Ключ=значение")
        k, v = e.split("=", 1)
        pairs.append((k, v))
    errs, warns, changed, new = params_check(proto, mtu, old, pairs)
    out = [f"K\t{k}\t{new.get(k, 'off' if k in SWITCHES else '')}" for k in params_editable(proto)]
    out += [f"E\t{x}" for x in errs] + [f"W\t{x}" for x in warns]
    out += [f"C\t{k}" for k in changed] + [f"B\t{k}" for k in changed if k in BREAKING]
    out += [f"P\t{k} = {new[k]}" for k in AWG_PARAM_KEYS if k in new]
    print("\n".join(out))


def cmd_keepalive_set(path, value):
    text = read(path)
    new = re.sub(r"^PersistentKeepalive\s*=.*$", "PersistentKeepalive = " + value, text, flags=re.M)
    if new != text:
        write_atomic(path, new)


def cmd_i_replace(path):
    """Заменить строки I1-I5 клиента на строки из stdin (пусто — убрать)."""
    lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
    out, inserted = [], False
    for line in read(path).split("\n"):
        if re.match(r"^I[1-5]\s*=", line):
            continue
        if PEER_SPLIT.match(line) and not inserted:
            while out and out[-1] == "":
                out.pop()
            out.extend(lines)
            out.append("")
            inserted = True
        out.append(line)
    write_atomic(path, "\n".join(out))


# ── Срок действия клиентов ──
def cmd_expire_set(conf, name, ts):
    head, peers = split_peers(read(conf))
    i = find_peer(peers, name=name)
    if i < 0:
        die("клиент %s не найден" % name, 2)
    peers[i] = set_meta(peers[i], "expires", ts)
    write_atomic(conf, head + "".join(peers))


def cmd_expire_clear(conf, name, suspend):
    head, peers = split_peers(read(conf))
    i = find_peer(peers, name=name)
    if i < 0:
        die("клиент %s не найден" % name, 2)
    b = peers[i]
    if peer_meta(b, "blocked_by") == "traffic":
        # Блокировку держит лимит трафика: снимается только срок
        peers[i] = set_meta(b, "expires", "")
        write_atomic(conf, head + "".join(peers))
        print("traffic")
        return
    orig = peer_meta(b, "orig_ips")
    if orig and peer_field(b, "AllowedIPs") == suspend:
        b = re.sub(r"^([ \t]*AllowedIPs\s*=\s*).+$", lambda m: m.group(1) + orig, b, count=1, flags=re.M | re.I)
    b = set_meta(set_meta(set_meta(b, "expires", ""), "orig_ips", ""), "blocked_by", "")
    peers[i] = b
    write_atomic(conf, head + "".join(peers))
    print(orig)


def cmd_expire_check(conf, suspend, state_dir):
    """Блокирует истёкших (AllowedIPs → suspend, исходный адрес в orig_ips)
    и предупреждает за час до срока. Печатает события построчно:
    CHANGED; EXPIRED<TAB>имя<TAB>адрес; WARN1H<TAB>имя<TAB>минут."""
    try:
        text = read(conf)
    except OSError:
        return
    now = int(time.time())
    head, peers = split_peers(text)
    events, changed = [], False
    for i, b in enumerate(peers):
        exp, pub, aip = peer_meta(b, "expires"), peer_field(b, "PublicKey"), peer_field(b, "AllowedIPs")
        if not (exp.isdigit() and pub and aip):
            continue
        exp = int(exp)
        name = peer_name(b) or pub[:8]
        if now >= exp and aip != suspend:
            if not peer_meta(b, "orig_ips"):
                b = set_meta(b, "orig_ips", aip)
            b = re.sub(r"^([ \t]*AllowedIPs\s*=\s*).+$", lambda m: m.group(1) + suspend, b, count=1, flags=re.M | re.I)
            peers[i] = b
            changed = True
            events.append("EXPIRED\t%s\t%s" % (name, aip))
        elif aip != suspend and 0 < exp - now <= 3600:
            lock = os.path.join(state_dir, "warn1h_" + re.sub(r"[^A-Za-z0-9]", "_", pub))
            if not os.path.exists(lock):
                events.append("WARN1H\t%s\t%d" % (name, max(1, (exp - now) // 60)))
                try:
                    os.makedirs(state_dir, exist_ok=True)
                    with open(lock, "w") as f:
                        f.write(str(now))
                except OSError:
                    pass
    if changed:
        write_atomic(conf, head + "".join(peers))
        print("CHANGED")
    for e in events:
        print(e)


# ── Трафик клиентов и лимиты ──
# Счётчики `awg show transfer` живут, пока поднят интерфейс, поэтому таймер
# каждые 15 с складывает их прирост в базу: по дням (DAYS_KEEP дней) и за
# всё время. Ключ — публичный ключ: переименование историю не теряет.
# Лимит — метка пира «# limit=БАЙТ/month|total»; превысивший блокируется
# как истёкший (AllowedIPs → suspend), с меткой «# blocked_by=traffic» — по
# ней таймер разблокирует его в новом месяце или после смены лимита.
DAYS_KEEP = 92
TRAFFIC_SAVE_EVERY = 300
SIZE_UNITS = {"": 1024 ** 3, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}
SIZE_MAX = 1024 ** 5


def fmt_bytes(n):
    n = float(n or 0)
    for unit in ("Б", "КБ", "МБ", "ГБ"):
        if n < 1024:
            return "%d %s" % (n, unit) if unit == "Б" else "%.1f %s" % (n, unit)
        n /= 1024
    return "%.1f ТБ" % n


def parse_size(text):
    """«50G», «500M», «1.5T», «50» (гигабайты) → байты; None — не размер.
    «500B» без K/M/G/T — не гигабайты, а ошибка; больше 1 ПБ — тоже."""
    m = re.match(r"^\s*(\d{1,7}(?:[.,]\d{1,3})?)\s*([KMGT]?)(i?B)?\s*$", text or "", re.I | re.A)
    if not m or (m.group(3) and not m.group(2)):
        return None
    n = int(float(m.group(1).replace(",", ".")) * SIZE_UNITS[m.group(2).upper()])
    return n if 0 < n <= SIZE_MAX else None


def parse_limit(value):
    """Метка «БАЙТ/период» → (байт, период) или (0, "")."""
    m = re.match(r"^(\d+)/(month|total)$", value or "")
    return (int(m.group(1)), m.group(2)) if m else (0, "")


def _read_transfer(path):
    out = {}
    try:
        for line in read(path).splitlines():
            f = line.split("\t")
            if len(f) >= 3 and f[1].isdigit() and f[2].isdigit():
                out[f[0]] = (int(f[1]), int(f[2]))
    except OSError:
        pass
    return out


class Traffic:
    """База трафика: {"v", "ifindex", "saved", "last": {pub: [rx, tx]},
    "total": {pub: n}, "days": {"ГГГГ-ММ-ДД": {pub: [rx, tx]}},
    "reset": {pub: {"p": период, "b": байт}}, "warned": {pub: "период:лимит"}}."""

    def __init__(self, path):
        self.path = path
        try:
            data = json.loads(read(path))
        except (OSError, ValueError):
            data = {}
        self.fresh = not isinstance(data, dict) or "last" not in data
        if not isinstance(data, dict):
            data = {}
        self.d = {k: data.get(k) if isinstance(data.get(k), dict) else {}
                  for k in ("last", "total", "days", "reset", "warned")}
        self.ifindex = str(data.get("ifindex") or "")
        self.saved = int(data.get("saved") or 0)

    def apply(self, counters, ifindex=""):
        """Прирост счётчиков с прошлого раза — в сегодняшний день. Новый
        интерфейс (другой ifindex — awg0 пересоздан) или счётчик меньше
        прежнего — отсчёт с нуля. Самый первый проход только запоминает
        счётчики: накопленное до учёта к сегодняшнему дню не относится."""
        if self.fresh and not counters:
            # Счётчиков нет (интерфейс лежит) — запоминать нечего: иначе
            # следующий проход посчитал бы всё накопленное до учёта
            return
        today = time.strftime("%Y-%m-%d")
        last, total = self.d["last"], self.d["total"]
        reborn = bool(ifindex) and bool(self.ifindex) and ifindex != self.ifindex
        day = self.d["days"].setdefault(today, {})
        for pub, (rx, tx) in counters.items():
            prev = last.get(pub)
            if self.fresh:
                drx = dtx = 0
            elif reborn or not isinstance(prev, list) or len(prev) != 2 or rx < prev[0] or tx < prev[1]:
                drx, dtx = rx, tx
            else:
                drx, dtx = rx - prev[0], tx - prev[1]
            last[pub] = [rx, tx]
            if drx or dtx:
                cur = day.get(pub) or [0, 0]
                day[pub] = [cur[0] + drx, cur[1] + dtx]
                total[pub] = int(total.get(pub) or 0) + drx + dtx
        if ifindex:
            self.ifindex = ifindex
        self.fresh = False

    @staticmethod
    def period_key(period):
        return time.strftime("%Y-%m") if period == "month" else "total"

    def raw_used(self, pub, period):
        if period == "month":
            month = time.strftime("%Y-%m")
            return sum(sum(v.get(pub) or [0, 0]) for d, v in self.d["days"].items() if d.startswith(month))
        return int(self.d["total"].get(pub) or 0)

    def used(self, pub, period):
        raw = self.raw_used(pub, period)
        r = self.d["reset"].get(pub)
        if isinstance(r, dict) and r.get("p") == self.period_key(period):
            return max(0, raw - int(r.get("b") or 0))
        return raw

    def reset(self, pub, period):
        self.d["reset"][pub] = {"p": self.period_key(period), "b": self.raw_used(pub, period)}
        self.d["warned"].pop(pub, None)

    def series(self, pubs, days):
        """Последние days дней (от старых к новым): даты, rx и tx по списку ключей."""
        dates = [time.strftime("%Y-%m-%d", time.localtime(time.time() - 86400 * i)) for i in range(days - 1, -1, -1)]
        rx, tx = [], []
        for d in dates:
            v = self.d["days"].get(d) or {}
            rx.append(sum((v.get(p) or [0, 0])[0] for p in pubs))
            tx.append(sum((v.get(p) or [0, 0])[1] for p in pubs))
        return dates, rx, tx

    def save(self, alive=None):
        """Старше DAYS_KEEP дней — прочь; у удалённых клиентов остаётся
        только история по дням (она входит в общий трафик сервера)."""
        cutoff = time.strftime("%Y-%m-%d", time.localtime(time.time() - 86400 * DAYS_KEEP))
        self.d["days"] = {k: v for k, v in self.d["days"].items() if k >= cutoff and v}
        if alive is not None:
            for k in ("last", "total", "reset", "warned"):
                self.d[k] = {p: v for p, v in self.d[k].items() if p in alive}
        self.saved = int(time.time())
        data = dict(self.d, v=1, ifindex=self.ifindex, saved=self.saved)
        if self.fresh:
            # Счётчики ещё не запомнены: следующий проход — снова первый
            del data["last"]
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        write_atomic(self.path, json.dumps(data, separators=(",", ":")))


def _block(b, suspend, aip, reason):
    if not peer_meta(b, "orig_ips"):
        b = set_meta(b, "orig_ips", aip)
    b = re.sub(r"^([ \t]*AllowedIPs\s*=\s*).+$", lambda m: m.group(1) + suspend, b, count=1, flags=re.M | re.I)
    return set_meta(b, "blocked_by", reason)


def _unblock(b, suspend):
    orig = peer_meta(b, "orig_ips")
    if orig and peer_field(b, "AllowedIPs") == suspend:
        b = re.sub(r"^([ \t]*AllowedIPs\s*=\s*).+$", lambda m: m.group(1) + orig, b, count=1, flags=re.M | re.I)
    return set_meta(set_meta(b, "orig_ips", ""), "blocked_by", "")


PERIOD_WORD = {"month": "за месяц", "total": "всего"}


def cmd_traffic_tick(conf, suspend, db, transfer, ifindex="", force_save="0"):
    """Проход таймера: прирост трафика в базу и проверка лимитов. События:
    CHANGED; LIMIT<TAB>имя<TAB>адрес<TAB>текст; WARN90<TAB>имя<TAB>текст;
    UNLIMIT<TAB>имя<TAB>текст."""
    lock = _traffic_lock(db)
    try:
        text = read(conf)
    except OSError:
        return
    t = Traffic(db)
    t.apply(_read_transfer(transfer), ifindex)
    now = int(time.time())
    head, peers = split_peers(text)
    events, changed, alive = [], False, set()
    for i, b in enumerate(peers):
        pub, aip = peer_field(b, "PublicKey"), peer_field(b, "AllowedIPs")
        if not (pub and aip):
            continue
        alive.add(pub)
        name = peer_name(b) or pub[:8]
        limit, period = parse_limit(peer_meta(b, "limit"))
        by_traffic = peer_meta(b, "blocked_by") == "traffic"
        exp = peer_meta(b, "expires")
        expired = exp.isdigit() and now >= int(exp)
        used = t.used(pub, period) if limit else 0
        word = "%s из %s %s" % (fmt_bytes(used), fmt_bytes(limit), PERIOD_WORD.get(period, "")) if limit else ""
        if by_traffic and (not limit or used < limit):
            if expired:
                # Лимит отпустил, но истёк срок: блокировку держит уже он,
                # и снимается она сроком
                peers[i] = set_meta(b, "blocked_by", "")
            else:
                peers[i] = _unblock(b, suspend)
                events.append("UNLIMIT\t%s\t%s" % (name, word or "лимит снят"))
            changed = True
        elif limit and used >= limit and aip != suspend:
            peers[i] = _block(b, suspend, aip, "traffic")
            changed = True
            events.append("LIMIT\t%s\t%s\t%s" % (name, aip, word))
        elif limit and used >= limit * 0.9 and aip != suspend:
            mark = "%s:%d" % (t.period_key(period), limit)
            if t.d["warned"].get(pub) != mark:
                t.d["warned"][pub] = mark
                events.append("WARN90\t%s\t%s" % (name, word))
    if changed:
        write_atomic(conf, head + "".join(peers))
        print("CHANGED")
    day_changed = time.strftime("%Y-%m-%d", time.localtime(t.saved)) != time.strftime("%Y-%m-%d")
    if events or changed or day_changed or force_save == "1" or now - t.saved >= TRAFFIC_SAVE_EVERY:
        t.save(alive)
    del lock
    for e in events:
        print(e)


def _traffic_lock(db):
    """Таймер и вызовы API правят базу по очереди."""
    import fcntl
    try:
        os.makedirs(os.path.dirname(os.path.abspath(db)), exist_ok=True)
        f = open(db + ".lock", "a")
        fcntl.flock(f, fcntl.LOCK_EX)
        return f
    except OSError:
        return None


def cmd_limit_set(conf, db, name, size, period="month", transfer="", ifindex=""):
    """Лимит клиенту: размер («50G»), off — снять. Лимит «всего» считается
    с этой минуты; «за месяц» — с начала месяца. transfer — снимок
    `awg show transfer`: прирост до этой минуты в новый отсчёт не попадает."""
    if size != "off":
        n = parse_size(size)
        if n is None:
            die("размер не распознан: %s (пример: 50G, 500M)" % size)
        if period not in PERIOD_WORD:
            die("период: month или total")
    lock = _traffic_lock(db)
    head, peers = split_peers(read(conf))
    i = find_peer(peers, name=name)
    if i < 0:
        die("клиент %s не найден" % name, 2)
    if size == "off":
        peers[i] = set_meta(peers[i], "limit", "")
        write_atomic(conf, head + "".join(peers))
        return
    pub = peer_field(peers[i], "PublicKey")
    t = Traffic(db)
    if transfer:
        t.apply(_read_transfer(transfer), ifindex)
    old, old_period = parse_limit(peer_meta(peers[i], "limit"))
    if period == "total" and old_period != "total":
        t.reset(pub, "total")
    t.d["warned"].pop(pub, None)
    t.save()
    peers[i] = set_meta(peers[i], "limit", "%d/%s" % (n, period))
    write_atomic(conf, head + "".join(peers))
    del lock
    print(fmt_bytes(n))


def cmd_limit_reset(conf, db, name, transfer="", ifindex=""):
    """Обнулить счётчик лимита (до конца периода)."""
    lock = _traffic_lock(db)
    _, peers = split_peers(read(conf))
    i = find_peer(peers, name=name)
    if i < 0:
        die("клиент %s не найден" % name, 2)
    limit, period = parse_limit(peer_meta(peers[i], "limit"))
    if not limit:
        die("у клиента %s нет лимита" % name)
    t = Traffic(db)
    if transfer:
        t.apply(_read_transfer(transfer), ifindex)
    t.reset(peer_field(peers[i], "PublicKey"), period)
    t.save()
    del lock


def cmd_traffic_daily(conf, db, transfer, name="", days="30"):
    """Трафик по дням: сервер целиком (с разбивкой по клиентам) или один
    клиент. Несохранённый прирост счётчиков учитывается, база не пишется."""
    try:
        days = max(1, min(DAYS_KEEP, int(days)))
    except ValueError:
        days = 30
    _, peers = split_peers(read(conf))
    names = {peer_field(b, "PublicKey"): peer_name(b) for b in peers if peer_field(b, "PublicKey")}
    t = Traffic(db)
    t.apply(_read_transfer(transfer))
    if name:
        pubs = [p for p, n in names.items() if n == name]
        if not pubs:
            die("клиент %s не найден" % name, 2)
    else:
        pubs = sorted({p for v in t.d["days"].values() for p in v} | set(names))
    dates, rx, tx = t.series(pubs, days)
    out = {"name": name, "days": dates, "rx": rx, "tx": tx, "total": sum(rx) + sum(tx)}
    if not name:
        rows = []
        for p, n in names.items():
            _, r, s = t.series([p], days)
            if sum(r) + sum(s):
                rows.append({"name": n or p[:8], "rx": sum(r), "tx": sum(s)})
        out["clients"] = sorted(rows, key=lambda c: -(c["rx"] + c["tx"]))
    print(json.dumps(out, ensure_ascii=False))


def _wgobf_names(conf):
    """wgobf0.conf: ключ клиента → имя из «# client=имя» в его [Peer]."""
    names, name = {}, None
    for line in read(conf).splitlines():
        line = line.strip()
        if line == "[Peer]":
            name = None
        elif line.startswith("# client="):
            name = line[len("# client="):]
        elif name and line.startswith("PublicKey") and "=" in line:
            names[line.split("=", 1)[1].strip()] = name
    return names


def cmd_traffic_now(conf, transfer, wconf="", wtransfer=""):
    """Счётчики awg0 сейчас — для живой скорости в панели: время (с долями
    секунды) и {имя: [приём, отдача]}; клиенты WG + обфускатора (wgobf0) —
    отдельно в wpeers, имена у них свои. Только чтение, база трафика не трогается."""
    _, peers = split_peers(read(conf))
    names = {peer_field(b, "PublicKey"): peer_name(b) for b in peers if peer_field(b, "PublicKey")}
    out = {}
    for pub, (rx, tx) in _read_transfer(transfer).items():
        if pub in names:
            out[names[pub] or pub[:8]] = [rx, tx]
    wout = {}
    if wconf and wtransfer and os.path.isfile(wconf):
        wnames = _wgobf_names(wconf)
        for pub, (rx, tx) in _read_transfer(wtransfer).items():
            if pub in wnames:
                wout[wnames[pub]] = [rx, tx]
    print(json.dumps({"ts": round(time.time(), 3), "peers": out, "wpeers": wout}, ensure_ascii=False))


def cmd_traffic_rows(conf, db, transfer):
    """Для меню: имя, лимит (байт), период, использовано по лимиту, за
    месяц, сегодня, причина блокировки — построчно через табуляцию."""
    _, peers = split_peers(read(conf))
    t = Traffic(db)
    t.apply(_read_transfer(transfer))
    today = time.strftime("%Y-%m-%d")
    for b in peers:
        pub = peer_field(b, "PublicKey")
        if not pub:
            continue
        limit, period = parse_limit(peer_meta(b, "limit"))
        by = peer_meta(b, "blocked_by") or ("expire" if peer_meta(b, "orig_ips") else "")
        print("\t".join(str(x) for x in (
            peer_name(b), limit, period, t.used(pub, period) if limit else 0, t.raw_used(pub, "month"),
            sum((t.d["days"].get(today) or {}).get(pub) or [0, 0]), by)))


def cmd_traffic_report(conf, db, transfer, days="14"):
    """Трафик сервера по дням столбиками и клиенты за 30 дней — для меню."""
    try:
        days = max(1, min(DAYS_KEEP, int(days)))
    except ValueError:
        days = 14
    _, peers = split_peers(read(conf))
    names = {peer_field(b, "PublicKey"): peer_name(b) for b in peers if peer_field(b, "PublicKey")}
    t = Traffic(db)
    t.apply(_read_transfer(transfer))
    pubs = sorted({p for v in t.d["days"].values() for p in v} | set(names))
    dates, rx, tx = t.series(pubs, days)
    top = max([a + b for a, b in zip(rx, tx)] + [1])
    print("По дням (↓ от клиентов + ↑ к клиентам):")
    for d, a, b in zip(dates, rx, tx):
        bar = "▇" * int(round(28 * (a + b) / top)) if a + b else ""
        print("  %s.%s  %-28s %s" % (d[8:], d[5:7], bar, fmt_bytes(a + b) if a + b else "—"))
    print("  Итого за %d дн.: %s" % (days, fmt_bytes(sum(rx) + sum(tx))))
    rows = []
    for p, n in names.items():
        _, r, s = t.series([p], 30)
        if sum(r) + sum(s):
            rows.append((sum(r) + sum(s), n or p[:8]))
    if rows:
        print("")
        print("Клиенты за 30 дней:")
        for total, n in sorted(rows, reverse=True)[:15]:
            print("  %-24s %s" % (n, fmt_bytes(total)))


def cmd_size_parse(text):
    n = parse_size(text)
    if n is None:
        die("размер не распознан: %s" % text)
    print(n)


# ════════════════════════ сети ════════════════════════
def cmd_net_of(cidr):
    print(ipaddress.ip_network(cidr.split(",")[0].strip(), strict=False))


def cmd_pick_net(pool="wgobf"):
    """Свободная /24, не пересекающаяся ни с одним адресом и маршрутом из stdin.
    pool=awg — 10.[10-55].x (как всегда выбирался AWG), иначе пулы
    WG+обфускатора: 10.[60-99].x, 172.16-31.x, 192.168.x."""
    taken = []
    for tok in re.findall(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?(?![\d.])", sys.stdin.read()):
        try:
            n = ipaddress.ip_network(tok, strict=False)
        except ValueError:
            continue
        if n.prefixlen:
            taken.append(n)
    pools = [lambda: "10.%d.%d.0/24" % (random.randint(60, 99), random.randint(1, 254)),
             lambda: "172.%d.%d.0/24" % (random.randint(16, 31), random.randint(1, 254)),
             lambda: "192.168.%d.0/24" % random.randint(100, 250)]
    if pool == "awg":
        pools.insert(0, lambda: "10.%d.%d.0/24" % (random.randint(10, 55), random.randint(1, 254)))
    for pick in pools:
        for _ in range(300):
            net = ipaddress.ip_network(pick())
            if not any(net.overlaps(t) for t in taken):
                print(net)
                return
    die("свободной /24 нет")


def cmd_net_overlaps(cidr):
    """0 — сеть cidr пересекается с чем-то из stdin, 1 — свободна."""
    net = ipaddress.ip_network(cidr, strict=False)
    for tok in re.findall(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?(?![\d.])", sys.stdin.read()):
        try:
            n = ipaddress.ip_network(tok, strict=False)
        except ValueError:
            continue
        if n.prefixlen and net.overlaps(n):
            print(n)
            return
    sys.exit(1)


def cmd_allowed_except(ip):
    """AllowedIPs «весь IPv4, кроме сервера»: иначе пакеты обфускатора клиента
    к серверу уйдут в сам туннель. Работает на любой платформе, в отличие от FwMark."""
    srv = ipaddress.ip_network(ip + "/32")
    nets = sorted(ipaddress.ip_network("0.0.0.0/0").address_exclude(srv))
    print(", ".join(str(n) for n in nets) + ", ::/0")


def cmd_rand_key(n="32"):
    alphabet = string.ascii_letters + string.digits
    print("".join(secrets.choice(alphabet) for _ in range(int(n))))


def cmd_phobos_link(path, name):
    conf = open(path, "rb").read()
    print("phobos://" + base64.urlsafe_b64encode(conf).decode().rstrip("=")
          + "#" + urllib.parse.quote(name))


def cmd_exit_conf_fix(path):
    """Конфиг клиента к exit-ноде: Table = off обязателен (иначе awg-quick
    уведёт в туннель весь сервер вместе с SSH), DNS выбрасываем (awg-quick
    перепишет resolv.conf сервера или упадёт без resolvconf). PreUp/PostUp/
    PreDown/PostDown тоже: awg-quick выполняет их через bash от root, а конфиг
    приходит снаружи (вставка, бот, чужой бэкап) — это данные, не скрипт.
    SaveConfig — чтобы awg-quick не переписывал файл при остановке."""
    out, in_iface, added = [], False, False
    for line in read(path).replace("\r", "").split("\n"):
        if re.match(r"^\s*\[\s*interface\s*\]", line, re.I):
            in_iface = True
            out.append("[Interface]")
            out.append("Table = off")
            added = True
            continue
        if re.match(r"^\s*\[", line):
            in_iface = False
        if in_iface and re.match(r"^\s*(table|dns|preup|postup|predown|postdown|saveconfig)\s*=", line, re.I):
            continue
        out.append(line)
    if not added:
        die("нет секции [Interface]")
    write_atomic(path, "\n".join(out))


# Хуки awg-quick/wg-quick (PreUp/PostUp/PreDown/PostDown) выполняются через
# eval от root. Конфиг сервера из бэкапа мог прийти чужой — пропускаем только
# команды, какие пишет сама Тулза и её прежние версии: iptables/ip6tables,
# включение ip_forward, MTU интерфейса, true; плюс точные команды из allow.
HOOK_LINE = re.compile(r"^\s*(preup|postup|predown|postdown|saveconfig)\s*=\s*(.*?)\s*$", re.I)
_HOOK_REDIR = r"(?:\s+(?:2>/dev/null|>/dev/null(?:\s+2>&1)?|2>&1))*"
_HOOK_TOKEN = r"""(?:[A-Za-z0-9_.:/,!=+%@-]+|"[A-Za-z0-9_.:/,!=+%@ -]*"|'[A-Za-z0-9_.:/,!=+%@ -]*')"""
HOOK_SAFE = [
    re.compile(r"^(?:iptables|ip6tables)(?:\s+%s)+%s$" % (_HOOK_TOKEN, _HOOK_REDIR)),
    re.compile(r"^echo\s+1\s*>\s*/proc/sys/net/ipv4/ip_forward$"),
    re.compile(r"^sysctl\s+(?:-q\s+)?-q?w\s+net\.ipv4\.ip_forward=1%s$" % _HOOK_REDIR),
    re.compile(r"^ip\s+link\s+set\s+(?:dev\s+)?[A-Za-z0-9_.%%-]{1,15}\s+mtu\s+\d{3,5}%s$" % _HOOK_REDIR),
    re.compile(r"^true$"),
]


def _hook_cmd_safe(cmd, allow):
    if cmd in allow:
        return True
    if not any(r.match(cmd) for r in HOOK_SAFE):
        return False
    # iptables --modprobe=ПРОГРАММА (и сокращения getopt: --mod, --modp…)
    # запускает любую программу — такой «iptables» не пропускаем
    for tok in cmd.split():
        name = tok.strip("\"'").split("=", 1)[0]
        if name == "-M" or (len(name) > 3 and "--modprobe".startswith(name)) or name.startswith("--modprobe"):
            return False
    return True


def cmd_conf_hooks(path, mode, *allow):
    """Хуки конфига сервера: check — напечатать недопустимые команды
    («ключ<TAB>команда»), fix — убрать их из файла (допустимые остаются,
    SaveConfig — всегда). Команды делятся по «;», «||» и «&&»: недопустима
    хоть одна ветка — убирается вся команда."""
    if mode not in ("check", "fix"):
        die("режим: check | fix")
    out, bad, in_iface = [], [], False
    for line in read(path).split("\n"):
        if re.match(r"^\s*\[", line):
            in_iface = bool(re.match(r"^\s*\[\s*interface\s*\]", line, re.I))
        m = HOOK_LINE.match(line) if in_iface else None
        if not m:
            out.append(line)
            continue
        key, value = m.group(1), m.group(2)
        if key.lower() == "saveconfig":
            bad.append((key, line.strip()))
            continue
        keep = []
        for cmd in (c.strip() for c in value.split(";")):
            if not cmd:
                continue
            if all(_hook_cmd_safe(alt.strip(), allow) for alt in re.split(r"\|\||&&", cmd)):
                keep.append(cmd)
            else:
                bad.append((key, cmd))
        if keep:
            out.append(line if len(keep) == len([c for c in value.split(";") if c.strip()])
                       else "%s = %s" % (key, "; ".join(keep)))
    for key, cmd in bad:
        print("%s\t%s" % (key, cmd))
    if mode == "fix" and bad:
        write_atomic(path, "\n".join(out))


# ════════════════════════ Xray ════════════════════════
SKIP_PROTO = ("freedom", "blackhole", "dns")
KNOWN_IN = {"xray0", "tun-in", "tun-probe", "socks-in"}
SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"]}


def jload(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def jsave(path, conf):
    write_atomic(path, json.dumps(conf, indent=2, ensure_ascii=False) + "\n", 0o600)


def proxy_tags(conf):
    return [o["tag"] for o in conf.get("outbounds", [])
            if o.get("tag") and o.get("protocol") not in SKIP_PROTO]


def apply_transport(ss, net, get):
    if net == "ws":
        cfg = {}
        if get("path"):
            cfg["path"] = get("path")
        if get("host"):
            cfg["headers"] = {"Host": get("host")}
        ss["wsSettings"] = cfg
    elif net == "grpc":
        cfg = {}
        svc = get("serviceName") or get("svc") or get("path")
        if svc:
            cfg["serviceName"] = svc
        if get("mode") == "multi":
            cfg["multiMode"] = True
        ss["grpcSettings"] = cfg
    elif net in ("xhttp", "splithttp"):
        # Без path сервер отдаёт 404 на корень: TLS проходит, трафика нет
        cfg = {k: get(k) for k in ("path", "host", "mode") if get(k)}
        if get("extra"):
            try:
                cfg["extra"] = json.loads(get("extra"))
            except ValueError:
                pass
        ss["xhttpSettings" if net == "xhttp" else "splithttpSettings"] = cfg
    elif net == "httpupgrade":
        ss["httpupgradeSettings"] = {k: get(k) for k in ("path", "host") if get(k)}
    elif net in ("h2", "http"):
        # Транспорт HTTP/2 из Xray убран в пользу XHTTP stream-one
        cfg = {"mode": "stream-one"}
        if get("path"):
            cfg["path"] = get("path")
        if get("host"):
            cfg["host"] = get("host").split(",")[0]
        ss["network"] = "xhttp"
        ss["xhttpSettings"] = cfg
        sys.stderr.write("NOTE:транспорт h2 переведён на XHTTP stream-one\n")
    elif net not in ("tcp", "raw", "", None):
        sys.stderr.write("UNSUPPORTED:%s\n" % net)


def apply_tls(ss, get, fallback_sni):
    sec = ss.get("security") or "none"
    if sec in ("", "none", "0"):
        ss["security"] = "none"
        return
    tls = {"serverName": get("sni") or get("host") or fallback_sni or "",
           "fingerprint": get("fp") or "chrome"}
    for src, dst in (("pbk", "publicKey"), ("sid", "shortId"), ("spx", "spiderX")):
        if get(src):
            tls[dst] = get(src)
    if get("alpn"):
        tls["alpn"] = get("alpn").split(",")
    if str(get("allowInsecure") or get("insecure") or "").lower() in ("1", "true"):
        _note_insecure()
    ss["realitySettings" if sec == "reality" else "tlsSettings"] = tls


def _note_insecure():
    """Xray 26 убрал allowInsecure: с ним отвергается весь конфиг. Вместо
    него — pinSHA256 (отпечаток сертификата сервера) или настоящий сертификат."""
    sys.stderr.write("NOTE:allowInsecure пропущен — Xray 26 его не принимает; самоподписанному "
                     "сертификату нужен pinSHA256 в ссылке\n")


def _port_num(value, proto):
    """Порт из ссылки: только ASCII-цифры, 1–65535; пусто — 443. Иначе
    Xray получал порт 0 или 99999 (и отвергал весь конфиг), а «443» из
    не-ASCII цифр падал трассировкой."""
    if value in (None, ""):
        return 443
    if isinstance(value, float) and value.is_integer():     # vmess: "port": 443.0
        value = int(value)
    value = str(value)
    if not re.fullmatch(r"[0-9]{1,9}", value) or not 1 <= int(value) <= 65535:
        die("%s: неверный порт: %s" % (proto, value))
    return int(value)


def _url_port(u, proto):
    """Порт из urlparse; «:0», «:99999» и не-цифры — ошибка, а не 443."""
    _, sep, port = u.netloc.rpartition("@")[2].rpartition(":")
    if not sep or "]" in port:
        return 443
    return _port_num(port, proto)


def tag_for(host):
    return "proxy_" + re.sub(r"[^A-Za-z0-9]", "_", host or "server")


def _hy2_outbound(link):
    """hysteria2:// → outbound Xray 26+: protocol hysteria (version 2) и
    транспорт hysteria; пароль — auth, TLS — SNI, ALPN (h3), ECH, pinSHA256.
    Обфускация salamander — finalmask, порт-хоппинг (mport) не переносится."""
    u = urllib.parse.urlparse(link)
    qs = urllib.parse.parse_qs(u.query)

    def get(k):
        return qs[k][0] if qs.get(k) else None
    host = u.hostname or ""
    auth = urllib.parse.unquote(u.username or "")
    if u.password is not None:
        auth += ":" + urllib.parse.unquote(u.password)
    if not host or not auth:
        die("hysteria2: в ссылке нет адреса или пароля")
    port = _url_port(u, "hysteria2")
    tls = {"serverName": get("sni") or host, "alpn": (get("alpn") or "h3").split(",")}
    if get("pinSHA256"):
        tls["pinnedPeerCertSha256"] = get("pinSHA256")
    if get("ech"):
        tls["echConfigList"] = get("ech")
    if str(get("insecure") or "").lower() in ("1", "true") and not get("pinSHA256"):
        _note_insecure()
    ss = {"network": "hysteria", "hysteriaSettings": {"version": 2, "auth": auth},
          "security": "tls", "tlsSettings": tls}
    if get("obfs"):
        if get("obfs") != "salamander":
            sys.stderr.write("UNSUPPORTED:obfs=%s\n" % get("obfs"))
            die("hysteria2: обфускация %s не поддерживается" % get("obfs"))
        if not get("obfs-password"):
            die("hysteria2: для salamander нужен obfs-password")
        ss["finalmask"] = {"udp": [{"type": "salamander", "settings": {"password": get("obfs-password")}}]}
    if get("mport"):
        sys.stderr.write("NOTE:порт-хоппинг (mport=%s) не переносится — только порт %d\n" % (get("mport"), port))
    return {"protocol": "hysteria", "tag": tag_for(host),
            "settings": {"version": 2, "address": host, "port": port}, "streamSettings": ss}


def _ss_outbound(link):
    """ss:// — SIP002 (метод:пароль в base64 или открыто @хост:порт) и
    старый формат (всё в base64). Плагины (obfs, v2ray-plugin) не переносятся."""
    body = link[5:].split("#", 1)[0]
    body, _, query = body.partition("?")
    body = body.rstrip("/")

    def b64(text):
        text = urllib.parse.unquote(text)
        try:
            return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return None
    if "@" in body:
        userinfo, hostport = body.rsplit("@", 1)
        dec = b64(userinfo)
        cred = dec if dec and ":" in dec else urllib.parse.unquote(userinfo)
    else:
        dec = b64(body) or ""
        if "@" not in dec:
            die("ss: ссылка не разобрана")
        cred, hostport = dec.rsplit("@", 1)
    method, _, password = cred.partition(":")
    host, _, port = hostport.rpartition(":")
    host = host.strip("[]")
    if not (method and password and host and port):
        die("ss: нужен метод, пароль, адрес и порт")
    port = _port_num(port, "ss")
    if "plugin=" in query:
        sys.stderr.write("UNSUPPORTED:ss-plugin\n")
        die("ss: плагины (obfs, v2ray-plugin) не поддерживаются")
    return {"protocol": "shadowsocks", "tag": tag_for(host),
            "settings": {"servers": [{"address": host, "port": port, "method": method, "password": password}]}}


def cmd_xray_link(link):
    link = link.strip()
    if link.startswith("vless://"):
        u = urllib.parse.urlparse(link)
        qs = urllib.parse.parse_qs(u.query)

        def get(k):
            return qs[k][0] if qs.get(k) else None
        host = u.hostname or ""
        ob = {"protocol": "vless", "tag": tag_for(host),
              "settings": {"vnext": [{"address": host, "port": _url_port(u, "vless"),
                                      "users": [{"id": urllib.parse.unquote(u.username or ""),
                                                 "encryption": get("encryption") or "none",
                                                 "flow": get("flow") or ""}]}]},
              "streamSettings": {"network": get("type") or "tcp",
                                 "security": get("security") or "none"}}
    elif link.startswith("vmess://"):
        raw = link[8:]
        data = json.loads(base64.b64decode(raw + "=" * (-len(raw) % 4)).decode("utf-8"))
        if not isinstance(data, dict):
            die("vmess: внутри ссылки ожидался JSON-объект")

        def get(k):
            v = data.get(k)
            return str(v) if v not in (None, "") else None
        host = str(data.get("add") or "")
        ob = {"protocol": "vmess", "tag": tag_for(host),
              "settings": {"vnext": [{"address": host, "port": _port_num(data.get("port"), "vmess"),
                                      "users": [{"id": data.get("id"),
                                                 "alterId": int(data.get("aid") or 0),
                                                 "security": data.get("scy") or "auto"}]}]},
              "streamSettings": {"network": data.get("net") or "tcp",
                                 "security": data.get("tls") or "none"}}
    elif link.startswith("trojan://"):
        u = urllib.parse.urlparse(link)
        qs = urllib.parse.parse_qs(u.query)

        def get(k):
            return qs[k][0] if qs.get(k) else None
        host = u.hostname or ""
        # Пароль trojan — вся часть до «@»: «p:a@host» — это пароль «p:a»
        password = urllib.parse.unquote(u.username or "")
        if u.password is not None:
            password += ":" + urllib.parse.unquote(u.password)
        ob = {"protocol": "trojan", "tag": tag_for(host),
              "settings": {"servers": [{"address": host, "port": _url_port(u, "trojan"),
                                        "password": password}]},
              "streamSettings": {"network": get("type") or "tcp", "security": get("security") or "tls"}}
    elif link.startswith("ss://"):
        print(json.dumps(_ss_outbound(link)))
        return
    elif link.startswith(("hysteria2://", "hy2://")):
        print(json.dumps(_hy2_outbound(link)))
        return
    else:
        die("поддерживаются vless://, vmess://, trojan://, ss://, hysteria2://")
    apply_transport(ob["streamSettings"], ob["streamSettings"]["network"], get)
    apply_tls(ob["streamSettings"], get, host)
    print(json.dumps(ob))


def cmd_xray_default(path):
    """Начальный конфиг. listen 127.0.0.1 у socks обязателен: иначе на сервере
    появляется открытый SOCKS5-релей без авторизации."""
    jsave(path, {
        "inbounds": [{"listen": "127.0.0.1", "port": 10808, "protocol": "socks",
                      "tag": "socks-in", "settings": {"auth": "noauth", "udp": True},
                      "sniffing": SNIFF}],
        "outbounds": [{"protocol": "freedom", "tag": "direct"}],
        "routing": {"domainStrategy": "AsIs", "rules": []},
    })


def cmd_xray_add(path):
    ob = json.loads(sys.stdin.read())
    conf = jload(path)
    outs = conf.setdefault("outbounds", [])
    if any(o.get("tag") == ob.get("tag") for o in outs):
        die("outbound %s уже есть" % ob.get("tag"), 3)
    at = next((i for i, o in enumerate(outs) if o.get("protocol") == "freedom"), len(outs))
    outs.insert(at, ob)
    # Новая ссылка становится выходом по умолчанию, если балансировщик не
    # включён; клиенты со своим выходом остаются на нём
    for r in conf.get("routing", {}).get("rules", []):
        if set(r.get("inboundTag") or []) & KNOWN_IN and not r.get("balancerTag") \
                and r.get("ruleTag") != XRAY_CLIENT_RULE:
            r["outboundTag"] = ob["tag"]
    jsave(path, conf)


def cmd_xray_del(path, *tags):
    conf = jload(path)
    conf["outbounds"] = [o for o in conf.get("outbounds", []) if o.get("tag") not in tags]
    jsave(path, conf)


XRAY_RESTORE_KEEP = ("outbounds", "routing", "observatory")


def _shown(v, n=40):
    """Имя из чужого файла — для вывода в терминал и бот: без управляющих
    символов и обратной косой (warn печатает через echo -e)."""
    return re.sub(r"[\x00-\x1f\x7f\\]", "?", str(v))[:n]


def cmd_xray_restore_clean(path):
    """Конфиг Xray из бэкапа (бэкап мог прийти чужой, Xray работает от root):
    остаются выходы, маршрутизация и observatory — то, что пишет сама Тулза.
    Входы пересоберёт xray-prepare (SOCKS только на 127.0.0.1); api, stats,
    reverse, log и прочие разделы, правила чужих входов и правила на
    несуществующие выходы — убираются. Правила своего входа tun с чужим тегом
    переводятся на tun-in: входов в конфиге уже нет, и xray-prepare их бы не
    узнал. Кривые записи (не объект, тег — не строка) — тоже убираются, а не
    роняют разбор всего конфига. Печатает, что убрано."""
    conf = jload(path)
    if not isinstance(conf, dict):
        die("не объект JSON")
    is_tag = lambda v: isinstance(v, str) and v != ""          # noqa: E731
    as_list = lambda v: v if isinstance(v, list) else []       # noqa: E731
    outs = [o for o in as_list(conf.get("outbounds"))
            if isinstance(o, dict) and (o.get("tag") is None or is_tag(o.get("tag")))]
    tags = {o["tag"] for o in outs if is_tag(o.get("tag"))}
    if not any(is_tag(o.get("tag")) and o.get("protocol") not in SKIP_PROTO for o in outs):
        die("нет выходов")
    inbounds = [i for i in as_list(conf.get("inbounds")) if isinstance(i, dict)]
    tun_tags = {i["tag"] for i in inbounds if i.get("protocol") == "tun" and is_tag(i.get("tag"))}
    known = KNOWN_IN | tun_tags
    routing = conf.get("routing") if isinstance(conf.get("routing"), dict) else {}
    balancers = [b for b in as_list(routing.get("balancers")) if isinstance(b, dict) and is_tag(b.get("tag"))]
    btags = {b["tag"] for b in balancers}
    rules, dropped_rules = [], 0
    for r in as_list(routing.get("rules")):
        inb = r.get("inboundTag") if isinstance(r, dict) else None
        ot = r.get("outboundTag") if isinstance(r, dict) else None
        bt = r.get("balancerTag") if isinstance(r, dict) else None
        if (not isinstance(r, dict)
                or (inb and not (isinstance(inb, list) and all(is_tag(t) for t in inb) and set(inb) & known))
                or (ot and not (is_tag(ot) and ot in tags))
                or (bt and not (is_tag(bt) and bt in btags))):
            dropped_rules += 1
            continue
        if inb:
            r["inboundTag"] = list(dict.fromkeys("tun-in" if t in tun_tags else t for t in inb))
        rules.append(r)
    clean = {"inbounds": [], "outbounds": outs,
             "routing": {"domainStrategy": routing.get("domainStrategy") if is_tag(routing.get("domainStrategy"))
                         else "AsIs", "rules": rules}}
    if balancers:
        clean["routing"]["balancers"] = balancers
    if isinstance(conf.get("observatory"), dict):
        clean["observatory"] = conf["observatory"]
    foreign = [_shown(i.get("tag") or i.get("protocol") or "?") for i in inbounds
               if not (is_tag(i.get("tag")) and i["tag"] in KNOWN_IN) and i.get("protocol") != "tun"]
    gone = ["входы: " + ", ".join(foreign)] if foreign else []
    gone += sorted(_shown(k) for k in conf if k not in XRAY_RESTORE_KEEP + ("inbounds",))
    if dropped_rules:
        gone.append("правил: %d" % dropped_rules)
    jsave(path, clean)
    print("; ".join(gone))


def cmd_xray_tags(path):
    for t in proxy_tags(jload(path)):
        print(t)


def probe_conf(outbound):
    return {"log": {"loglevel": "none"},
            "inbounds": [{"listen": "127.0.0.1", "port": 10808, "protocol": "socks",
                          "tag": "probe-in", "settings": {"auth": "noauth"}}],
            "outbounds": [outbound, {"protocol": "freedom", "tag": "direct"}]}


def cmd_xray_probe(out):
    """Конфиг для `xray run -test` из одного outbound (stdin)."""
    jsave(out, probe_conf(json.loads(sys.stdin.read())))


def cmd_xray_probe_tag(path, tag, out):
    ob = next((o for o in jload(path).get("outbounds", []) if o.get("tag") == tag), None)
    if ob is None:
        die("нет outbound %s" % tag, 2)
    jsave(out, probe_conf(ob))


def cmd_xray_test_copy(src, dst):
    """Копия конфига для `xray run -test`. Проверка с inbound tun создаёт
    устройство, а xray0 занят работающим Xray («device or resource busy») —
    у копии tun получает своё имя и адрес."""
    conf = jload(src)
    for i, ib in enumerate(x for x in conf.get("inbounds") or [] if x.get("protocol") == "tun"):
        st = ib.setdefault("settings", {})
        st["name"] = "xrt" + secrets.token_hex(3)
        st["address"] = ["198.18.%d.1/30" % (250 + i % 4)]
    jsave(dst, conf)


def cmd_xray_tun_probe(out):
    jsave(out, {"log": {"loglevel": "none"},
                "inbounds": [{"protocol": "tun", "tag": "tun-probe",
                              "settings": {"mtu": 1500, "stack": "gvisor",
                                           "address": ["172.16.250.1/30"]}}],
                "outbounds": [{"protocol": "freedom", "tag": "direct"}]})


def cmd_xray_balancer(path, strategy):
    if strategy not in ("random", "roundRobin", "leastPing", "leastLoad", "off"):
        die("стратегия: random|roundRobin|leastPing|leastLoad|off")
    conf = jload(path)
    tags = proxy_tags(conf)
    routing = conf.setdefault("routing", {})
    rules = routing.setdefault("rules", [])
    rule = next((r for r in rules if r.get("balancerTag") == "balancer"), None) or _xray_main_rule(rules)
    if strategy == "off":
        routing.pop("balancers", None)
        conf.pop("observatory", None)
        for r in rules:
            if r.pop("balancerTag", None) and tags:
                r["outboundTag"] = tags[0]
    else:
        if len(tags) < 2:
            die("нужно минимум 2 proxy-outbound")
        routing["balancers"] = [{"tag": "balancer", "selector": tags,
                                 "strategy": {"type": strategy}}]
        if rule is None:
            rule = {"type": "field", "inboundTag": ["socks-in"]}
            rules.append(rule)
        rule.pop("outboundTag", None)
        rule["balancerTag"] = "balancer"
        # leastPing/leastLoad выбирают по замерам observatory
        if strategy in ("leastPing", "leastLoad"):
            conf["observatory"] = {"subjectSelector": tags,
                                   "probeUrl": "https://www.google.com/generate_204",
                                   "probeInterval": "1m"}
        else:
            conf.pop("observatory", None)
    jsave(path, conf)


def cmd_xray_balancer_get(path):
    b = jload(path).get("routing", {}).get("balancers") or []
    print(b[0].get("strategy", {}).get("type", "random") if b else "off")


def cmd_xray_ru(path, mode):
    """РФ-сайты напрямую: .ru/.su/.рф, «только из РФ» и РФ-IP идут в direct.
    Правила встают над первым правилом, ведущим в туннель, — блокировки выше
    остаются выше."""
    conf = jload(path)
    routing = conf.setdefault("routing", {})
    rules = [r for r in routing.get("rules", []) if r.get("ruleTag") != "ru-direct"]
    if mode == "on":
        outs = conf.setdefault("outbounds", [])
        if not any(o.get("tag") == "direct" for o in outs):
            outs.append({"protocol": "freedom", "tag": "direct"})
        proxy = set(proxy_tags(conf))
        at = next((i for i, r in enumerate(rules)
                   if r.get("balancerTag") or r.get("outboundTag") in proxy
                   or r.get("outboundTag") == "proxy"), len(rules))
        rules[at:at] = [
            {"type": "field", "ruleTag": "ru-direct", "outboundTag": "direct",
             "domain": ["domain:ru", "domain:su", "domain:xn--p1ai",
                        "ext:geosite_RU.dat:ru-available-only-inside"]},
            {"type": "field", "ruleTag": "ru-direct", "outboundTag": "direct",
             "ip": ["ext:geoip_RU.dat:ru"]},
        ]
    routing["rules"] = rules
    jsave(path, conf)


XRAY_CLIENT_RULE = "client-out"


def _xray_main_rule(rules):
    """Правило, ведущее весь вход туннеля в выход по умолчанию или балансировщик."""
    return next((r for r in rules if set(r.get("inboundTag") or []) & KNOWN_IN
                 and r.get("ruleTag") != XRAY_CLIENT_RULE), None)


def cmd_xray_main(path, tag):
    """Выход по умолчанию для клиентов без своего выхода; балансировщик выключается."""
    conf = jload(path)
    if tag not in proxy_tags(conf):
        die("выхода %s нет" % tag, 2)
    routing = conf.setdefault("routing", {})
    rules = routing.setdefault("rules", [])
    routing.pop("balancers", None)
    conf.pop("observatory", None)
    rule = _xray_main_rule(rules)
    if rule is None:
        rule = {"type": "field", "inboundTag": ["socks-in"]}
        rules.append(rule)
    rule.pop("balancerTag", None)
    rule["outboundTag"] = tag
    jsave(path, conf)


def cmd_xray_main_get(path):
    rule = _xray_main_rule(jload(path).get("routing", {}).get("rules", []))
    print("balancer" if rule and rule.get("balancerTag") else (rule or {}).get("outboundTag", ""))


def cmd_xray_prepare(path, mode, peers=""):
    """Привести конфиг к режиму входа: native (inbound tun в самом Xray) или
    tun2socks (только SOCKS на 127.0.0.1:10808, xray0 поднимает tun2socks).
    Заодно чинит висячие ссылки на удалённые outbounds и балансировщик —
    с ними Xray отвергает конфиг целиком.

    peers — список клиентов Xray («IP» или «IP|выход»): клиентам со своим
    выходом — правила по адресу (source) перед общим правилом. Только для
    native: inbound tun видит адрес клиента (перед xray0 нет NAT), а через
    tun2socks все соединения приходят с 127.0.0.1."""
    conf = jload(path)
    conf.setdefault("routing", {})["rules"] = [r for r in conf["routing"].get("rules") or []
                                               if r.get("ruleTag") != XRAY_CLIENT_RULE]
    inb = [i for i in conf.get("inbounds") or []
           if not (i.get("tag") == "xray0" and i.get("protocol") == "dokodemo-door")]
    socks = next((i for i in inb if i.get("tag") == "socks-in"), None)
    if socks is None:
        socks = {"protocol": "socks", "tag": "socks-in",
                 "settings": {"auth": "noauth", "udp": True}, "sniffing": SNIFF}
        inb.append(socks)
    socks["listen"] = "127.0.0.1"
    socks["port"] = socks.get("port") or 10808
    tun = next((i for i in inb if i.get("protocol") == "tun"), None)
    # Тег входа tun — всегда свой: с чужим («tun» из правленного руками или
    # восстановленного конфига) общее правило переставало узнаваться, и
    # каждый проход дописывал новое, а старое продолжало вести в прежний выход
    known = set(KNOWN_IN)
    if tun is not None and tun.get("tag"):
        known.add(tun["tag"])
    if mode == "native":
        if tun is None:
            tun = {"protocol": "tun", "tag": "tun-in",
                   "settings": {"mtu": 1200, "stack": "gvisor", "address": ["172.16.250.1/30"]},
                   "sniffing": SNIFF}
            inb.insert(0, tun)
        tun["tag"] = "tun-in"
        want = tun["tag"]
    else:
        inb = [i for i in inb if i.get("protocol") != "tun"]
        want = "socks-in"
    conf["inbounds"] = inb

    routing = conf.setdefault("routing", {})
    routing.setdefault("domainStrategy", "AsIs")
    rules = routing.setdefault("rules", [])
    touched = False
    for r in rules:
        tags = r.get("inboundTag")
        if isinstance(tags, list) and any(t in known for t in tags):
            r["inboundTag"] = [want]
            touched = True
    ptags = proxy_tags(conf)
    if not touched:
        rules.append({"type": "field", "inboundTag": [want],
                      "outboundTag": ptags[0] if ptags else "proxy"})

    existing = {o.get("tag") for o in conf.get("outbounds", []) if o.get("tag")}
    balancers = routing.get("balancers") or []
    for b in balancers:
        b["selector"] = [t for t in (b.get("selector") or []) if t in existing]
    # Балансировать между одним выходом нечего
    balancers = [b for b in balancers if len(b["selector"]) >= 2]
    if balancers:
        routing["balancers"] = balancers
    else:
        routing.pop("balancers", None)
    obs = conf.get("observatory")
    if obs and balancers:
        obs["subjectSelector"] = [t for t in obs.get("subjectSelector") or [] if t in existing]
    elif obs:
        conf.pop("observatory")
    btags = {b.get("tag") for b in balancers}
    for r in rules:
        if r.get("balancerTag") and r["balancerTag"] not in btags:
            r.pop("balancerTag")
        ot = r.get("outboundTag")
        if not r.get("balancerTag") and (not ot or ot not in existing):
            if ptags:
                r["outboundTag"] = ptags[0]
            else:
                r.pop("outboundTag", None)
    rules = [r for r in rules if r.get("outboundTag") or r.get("balancerTag")]
    lst = _peers_list(peers) if peers and mode == "native" else None
    if lst:
        by_tag = {}
        for ip, tag in lst.items():
            if tag in existing and tag in ptags:
                by_tag.setdefault(tag, []).append(ip)
        main = _xray_main_rule(rules)
        at = rules.index(main) if main in rules else len(rules)
        rules[at:at] = [{"type": "field", "ruleTag": XRAY_CLIENT_RULE, "inboundTag": [want],
                         "source": sorted(ips, key=lambda x: [int(p) for p in x.split(".")] if x.count(".") == 3 else [0]),
                         "outboundTag": tag} for tag, ips in by_tag.items()]
    routing["rules"] = rules
    jsave(path, conf)


# ════════════════════════ DPI-тест ════════════════════════
def pcap_payloads(path):
    out = []
    with open(path, "rb") as f:
        if len(f.read(24)) < 24:
            return out
        while True:
            ph = f.read(16)
            if len(ph) < 16:
                break
            pkt = f.read(struct.unpack("<I", ph[8:12])[0])
            if len(pkt) < 42 or struct.unpack(">H", pkt[12:14])[0] != 0x0800:
                continue
            udp = 14 + (pkt[14] & 0x0F) * 4
            if udp + 8 > len(pkt):
                continue
            ln = struct.unpack(">H", pkt[udp + 4:udp + 6])[0]
            p = pkt[udp + 8:udp + ln]
            if len(p) >= 10:
                out.append(p)
    return out


def detect(p):
    for m in (b"REGISTER", b"INVITE", b"OPTIONS", b"SIP/2.0"):
        if p.startswith(m):
            return "sip", "SIP %s (%dB)" % (m.decode(), len(p))
    if p[0] == 0x16 and p[1:3] in (b"\xfe\xfd", b"\xfe\xff"):
        return "dtls", "DTLS handshake (%dB)" % len(p)
    if p.startswith(b"M-SEARCH"):
        return "ssdp", "SSDP M-SEARCH (%dB)" % len(p)
    if len(p) >= 20 and p[4:8] == b"\x21\x12\xa4\x42":
        mt = struct.unpack(">H", p[0:2])[0]
        if mt in (0x0001, 0x000A):
            kind = "TURN Allocate" if mt == 0x000A else "STUN Binding"
            ml = struct.unpack(">H", p[2:4])[0]
            if 20 + ml < len(p) and p[20 + ml] == 0x16:
                return "webrtc", "WebRTC: %s + DTLS (%dB)" % (kind, len(p))
            return "stun", "%s (%dB)" % (kind, len(p))
    if len(p) == 48 and p[0] == 0x23 and p[12:16] == b"INIT":
        return "ntp", "NTP client (%dB)" % len(p)
    if len(p) >= 13 and (p[2] >> 7) == 0 and ((p[2] >> 3) & 0xF) == 0 \
            and 1 <= struct.unpack(">H", p[4:6])[0] <= 10 and 1 <= p[12] <= 63:
        return "dns", "DNS query (%dB)" % len(p)
    fb = p[0]
    if (fb >> 6) == 3 and len(p) >= 7 and p[1:5].hex() in ("00000001", "6b3343cf") and 1 <= p[5] <= 20:
        return "quic", "QUIC Initial (%dB)" % len(p)
    # Узко по длинам генератора: 0x80 в первом байте бывает и у данных AWG
    if len(p) in (172, 108) and p[0] == 0x80 and (p[1] & 0x7F) in (0, 8, 96):
        return "rtp", "RTP pt=%d (%dB)" % (p[1] & 0x7F, len(p))
    return None, None


def cmd_pcap_analyze(path):
    payloads = pcap_payloads(path)
    if not payloads:
        print("VERDICT|EMPTY|Пакетов не захвачено")
        return
    found, other = [], 0
    for p in payloads:
        t, d = detect(p)
        if t:
            found.append((t, d))
        else:
            other += 1
    print("INFO|Захвачено пакетов: %d" % len(payloads))
    seen = []
    for t, d in found:
        if t not in seen:
            seen.append(t)
            print("OK|" + d)
    if other:
        print("INFO|Прочих пакетов AWG: %d (не распознаются как WireGuard)" % other)
    if found:
        print("VERDICT|PASS|Цепочка мимикрии: %d пакет(ов) — %s" % (len(found), ", ".join(seen)))
    else:
        print("VERDICT|OK|Обфускация работает; пакеты мимикрии прошли до начала захвата")


# ════════════════════════ машинный API ════════════════════════
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def _typed(val, typ):
    """Значение по типу ключа: s строка, n число, b да/нет, j JSON, f файл."""
    if typ == "n":
        try:
            return int(val)
        except ValueError:
            try:
                return float(val)
            except ValueError:
                return None
    if typ == "b":
        return val.strip().lower() in ("1", "true", "yes", "on", "y")
    if typ == "j":
        return json.loads(val) if val.strip() else None
    if typ == "f":
        try:
            return ANSI.sub("", read(val))
        except OSError:
            return ""
    return val


def _stdin_lines():
    """Строки stdin по \\n. splitlines() делил бы и по \\r, \\x1c-\\x1e, U+2028 —
    и свободный текст (комментарий, команда задачи) распадался на две строки."""
    return [l[:-1] if l.endswith("\r") else l for l in sys.stdin.read().split("\n")]


def _split_key(key):
    name, _, typ = key.partition(":")
    return name, typ or "s"


def cmd_json_kv():
    """Строки «ключ[:тип]<TAB>значение» → объект; точки в ключе — вложенность."""
    out = {}
    for line in _stdin_lines():
        if "\t" not in line:
            continue
        key, val = line.split("\t", 1)
        name, typ = _split_key(key)
        cur = out
        parts = name.split(".")
        for part in parts[:-1]:
            cur = cur.setdefault(part, {})
        cur[parts[-1]] = _typed(val, typ)
    print(json.dumps(out, ensure_ascii=False))


def cmd_json_rows(*cols):
    """Строки TSV → список объектов по колонкам «имя[:тип]»."""
    spec = [_split_key(c) for c in cols]
    rows = []
    for line in _stdin_lines():
        if not line:
            continue
        vals = line.split("\t")
        vals += [""] * (len(spec) - len(vals))
        rows.append({name: _typed(v, typ) for (name, typ), v in zip(spec, vals)})
    print(json.dumps(rows, ensure_ascii=False))


def cmd_json_list():
    """Непустые строки stdin → JSON-массив строк."""
    print(json.dumps([l for l in _stdin_lines() if l], ensure_ascii=False))


def _peers_list(path):
    """peers.list туннеля → {ip: нода или ""}; None — файла нет."""
    try:
        text = read(path)
    except OSError:
        return None
    out = {}
    for line in text.splitlines():
        ip, _, node = line.strip().partition("|")
        if ip:
            out[ip] = node
    return out


def _first_ip(value):
    return value.split(",")[0].split("/")[0].strip()


def cmd_clients_json(conf, dump, client_dir, warp, xray, exits, db=""):
    """Клиенты awg0 со статистикой `awg show dump`, туннелями и трафиком за
    месяц и по лимиту — для бота."""
    _, peers = split_peers(read(conf))
    stats = {}
    try:
        for line in read(dump).splitlines()[1:]:
            f = line.split("\t")
            if len(f) >= 7:
                stats[f[0]] = f
    except OSError:
        pass
    traffic = Traffic(db) if db else None
    if traffic:
        traffic.apply({k: (int(f[5]), int(f[6])) for k, f in stats.items() if f[5].isdigit() and f[6].isdigit()})
    today = time.strftime("%Y-%m-%d")
    now = int(time.time())
    tunnels = {"warp": _peers_list(warp), "xray": _peers_list(xray), "exit": _peers_list(exits)}
    rows = []
    for b in peers:
        pub = peer_field(b, "PublicKey")
        if not pub:
            continue
        name = peer_name(b)
        orig = peer_meta(b, "orig_ips")
        ip = _first_ip(orig or peer_field(b, "AllowedIPs"))
        exp = peer_meta(b, "expires")
        s = stats.get(pub) or ["", "", "", "", "0", "0", "0"]
        hs = int(s[4]) if s[4].isdigit() else 0
        path = ""
        for suf in ("_awg3.conf", "_awg2.conf"):
            p = os.path.join(client_dir, name + suf)
            if name and os.path.isfile(p):
                path = p
                break
        row = {
            "name": name, "ip": ip, "pub": pub,
            "expires": int(exp) if exp.isdigit() else None, "blocked": bool(orig),
            "mimicry": peer_meta(b, "mimicry") or "none",
            "handshake": hs, "ago": now - hs if hs else None,
            "online": bool(hs) and now - hs < 180,
            "rx": int(s[5]) if s[5].isdigit() else 0, "tx": int(s[6]) if s[6].isdigit() else 0,
            "endpoint": "" if s[2] in ("", "(none)") else s[2], "file": path,
        }
        limit, period = parse_limit(peer_meta(b, "limit"))
        by = peer_meta(b, "blocked_by")
        row.update(limit=limit or None, period=period or None,
                   blocked_by=(by or "expire") if orig else None,
                   used=traffic.used(pub, period) if traffic and limit else None,
                   month=traffic.raw_used(pub, "month") if traffic else None,
                   today=sum((traffic.d["days"].get(today) or {}).get(pub) or [0, 0]) if traffic else None)
        for t, lst in tunnels.items():
            if lst is None:
                row[t] = None
            elif t == "exit":
                row[t] = (lst[ip] or "shared") if ip in lst else "off"
            else:
                row[t] = ip in lst
        # Свой выход Xray клиента (пусто — выход по умолчанию)
        row["xray_out"] = (tunnels["xray"] or {}).get(ip) or ""
        rows.append(row)
    print(json.dumps(rows, ensure_ascii=False))


def _job_info(jdir, active):
    try:
        meta = json.loads(read(os.path.join(jdir, "meta.json")))
    except (OSError, ValueError):
        meta = {"id": os.path.basename(jdir)}
    try:
        res = json.loads(read(os.path.join(jdir, "result.json")))
    except (OSError, ValueError):
        res = None
    if res is not None:
        meta["state"] = "done"
        meta.update({k: res.get(k) for k in ("ok", "rc", "data", "error")})
        try:
            meta["finished"] = int(os.path.getmtime(os.path.join(jdir, "result.json")))
        except OSError:
            pass
    else:
        meta["state"] = "running" if active == "1" else "lost"
    return meta


def cmd_api_job_status(jdir, offset, active):
    """Состояние задачи и новый кусок журнала с байта offset. Кусок режется
    по концу строки: следующий опрос продолжит с целой строки."""
    info = _job_info(jdir, active)
    try:
        off = max(0, int(offset))
    except ValueError:
        off = 0
    try:
        with open(os.path.join(jdir, "log"), "rb") as f:
            f.seek(off)
            chunk = f.read(256 * 1024)
    except OSError:
        chunk = b""
    if info["state"] == "running":
        cut = chunk.rfind(b"\n") + 1
        chunk = chunk[:cut]
    info["offset"] = off + len(chunk)
    info["log"] = ANSI.sub("", chunk.decode("utf-8", "replace"))
    print(json.dumps(info, ensure_ascii=False))


def cmd_api_jobs(jobs_dir, *active_ids):
    """Последние 20 задач, новые сверху; active_ids — задачи с живым юнитом."""
    try:
        ids = sorted(os.listdir(jobs_dir), reverse=True)[:20]
    except OSError:
        ids = []
    rows = []
    for i in ids:
        info = _job_info(os.path.join(jobs_dir, i), "1" if i in active_ids else "0")
        info.pop("data", None)
        rows.append(info)
    print(json.dumps(rows, ensure_ascii=False))


def cmd_tg_targets(conf, admins_json):
    """Кому слать уведомления от таймеров: токен, прокси бота и ID
    владельцев (ADMIN_ID, у старых ботов ADMIN_CHAT_ID) и приглашённых
    админов — построчно. Пустой вывод — бот не настроен."""
    vals = {}
    try:
        for line in read(conf).splitlines():
            k, sep, v = line.strip().partition("=")
            if sep and not k.startswith("#"):
                vals[k.strip().upper()] = v.strip().strip("\"'")
    except OSError:
        return
    ids = []
    for part in re.split(r"[,;\s]+", vals.get("ADMIN_ID") or vals.get("ADMIN_CHAT_ID", "")):
        if part.isdigit() and part not in ids:
            ids.append(part)
    try:
        for k in (json.loads(read(admins_json)).get("admins") or {}):
            if str(k).isdigit() and str(k) not in ids:
                ids.append(str(k))
    except (OSError, ValueError, AttributeError):
        pass
    token = vals.get("BOT_TOKEN", "")
    if token and ids:
        print("\n".join([token, vals.get("BOT_PROXY", "")] + ids))


def cmd_api_envelope(rc, data_file, log_file):
    try:
        raw = read(data_file).strip()
    except OSError:
        raw = ""
    try:
        data = json.loads(raw) if raw else None
    except ValueError:
        data = None
    try:
        log = ANSI.sub("", read(log_file))
    except OSError:
        log = ""
    log = "\n".join(line.rstrip() for line in log.splitlines()).strip("\n")
    error = ""
    if rc != "0":
        errs = [l.strip()[1:].strip() for l in log.splitlines() if l.strip().startswith("×")]
        error = errs[-1] if errs else (log.splitlines()[-1].strip() if log else "код %s" % rc)
    print(json.dumps({"ok": rc == "0", "rc": int(rc), "data": data, "log": log, "error": error},
                     ensure_ascii=False))


# ════════════════════════ архивы ════════════════════════
# ── Готовые сертификаты сервера ───────────────────────────
# Сертификаты, которые уже выпустили другие программы (Caddy, certbot,
# acme.sh, Marzban, 3x-ui, nginx), — Mini App может взять их, не трогая
# порт 80: продлевает их тот, кто выпустил. Подходит только публичный
# сертификат (не самоподписанный), с ключом от него, не истекающий в
# ближайшие сутки и выписанный на этот сервер — IP сервера или домен,
# который ведёт на него.
CERT_GLOBS = (
    ("Caddy", "var/lib/caddy/.local/share/caddy/certificates/*/*/*.crt", "{dir}/{stem}.key"),
    ("Caddy", "root/.local/share/caddy/certificates/*/*/*.crt", "{dir}/{stem}.key"),
    ("Caddy", "home/*/.local/share/caddy/certificates/*/*/*.crt", "{dir}/{stem}.key"),
    ("Caddy", "var/lib/docker/volumes/*/_data/caddy/certificates/*/*/*.crt", "{dir}/{stem}.key"),
    ("Caddy", "var/lib/docker/volumes/*/_data/certificates/*/*/*.crt", "{dir}/{stem}.key"),
    ("certbot", "etc/letsencrypt/live/*/fullchain.pem", "{dir}/privkey.pem"),
    ("acme.sh", "root/.acme.sh/*/fullchain.cer", "{dir}/{dirname}.key"),
    ("Marzban", "var/lib/marzban/certs/*/fullchain.pem", "{dir}/key.pem"),
    ("Marzban", "var/lib/marzban/certs/fullchain.pem", "{dir}/key.pem"),
    ("3x-ui", "root/cert/*/fullchain.pem", "{dir}/privkey.pem"),
    ("3x-ui", "root/cert/fullchain.pem", "{dir}/privkey.pem"),
)
NGINX_GLOBS = ("etc/nginx/nginx.conf", "etc/nginx/conf.d/*.conf", "etc/nginx/sites-enabled/*")


def _openssl(*args, data=None):
    import subprocess
    try:
        r = subprocess.run(["openssl", *args], input=data, capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def _cert_candidates(root):
    import glob
    seen = set()
    for source, pat, key_tpl in CERT_GLOBS:
        for crt in sorted(glob.glob(os.path.join(root, pat))):
            d = os.path.dirname(crt)
            stem = os.path.basename(crt).rsplit(".", 1)[0]
            dirname = os.path.basename(d).removesuffix("_ecc")
            key = key_tpl.format(dir=d, stem=stem, dirname=dirname)
            if (crt, key) not in seen:
                seen.add((crt, key))
                yield source, crt, key
    # nginx: пары ssl_certificate / ssl_certificate_key в порядке появления
    for pat in NGINX_GLOBS:
        for conf in sorted(glob.glob(os.path.join(root, pat))):
            try:
                text = read(conf)
            except (OSError, UnicodeDecodeError):
                continue
            crt = None
            for m in re.finditer(r"^\s*(ssl_certificate(?:_key)?)\s+([^;\s]+)\s*;", text, re.M):
                path = m[2].strip("'\"")
                if not path.startswith("/") or "$" in path:
                    continue
                path = os.path.join(root, path.lstrip("/"))
                if m[1] == "ssl_certificate":
                    crt = path
                elif crt and (crt, path) not in seen:
                    seen.add((crt, path))
                    yield "nginx", crt, path
                    crt = None


def _cert_info(crt, key):
    """{names, ips, expires} публичного сертификата с подходящим ключом; иначе None."""
    try:
        if not (os.path.isfile(crt) and os.path.isfile(key)) or os.path.getsize(crt) > 1 << 20:
            return None
    except OSError:
        return None
    out = _openssl("x509", "-in", crt, "-noout", "-enddate", "-subject", "-issuer", "-ext", "subjectAltName",
                   "-nameopt", "RFC2253")
    if out is None:
        return None
    text = out.decode("utf-8", "replace")
    sub = re.search(r"^subject=(.*)$", text, re.M)
    iss = re.search(r"^issuer=(.*)$", text, re.M)
    if not sub or not iss or sub[1].strip() == iss[1].strip():
        return None                               # самоподписанный — Telegram не примет
    end = re.search(r"^notAfter=(.*)$", text, re.M)
    if not end:
        return None
    # «Dec  3 12:00:00 2026 GMT» — месяц по-английски при любой локали сервера
    m = re.match(r"([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})", end[1].strip())
    months = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
    if not m or m[1] not in months:
        return None
    import calendar
    expires = calendar.timegm((int(m[6]), months.index(m[1]) + 1, int(m[2]), int(m[3]), int(m[4]), int(m[5]), 0, 0, 0))
    if expires < time.time() + 86400:
        return None
    pub_c = _openssl("x509", "-in", crt, "-noout", "-pubkey")
    pub_k = _openssl("pkey", "-in", key, "-pubout")
    if not pub_c or not pub_k or pub_c.strip() != pub_k.strip():
        return None                               # ключ не от этого сертификата
    names = re.findall(r"DNS:([^,\s]+)", text)
    ips = re.findall(r"IP Address:([0-9.]+)", text)
    return {"names": [n.lower() for n in names if not n.startswith("*.")], "ips": ips, "expires": expires}


def _resolves_to(name, ip):
    import socket
    try:
        return ip in {a[4][0] for a in socket.getaddrinfo(name, None, socket.AF_INET)}
    except (OSError, UnicodeError):
        return False


def cmd_cert_find(pub_ip, root="/", *exclude):
    """Готовые сертификаты для Mini App: строки «имя<TAB>источник<TAB>сертификат
    <TAB>ключ<TAB>до (unix)», свежие сверху; одно имя — один, самый долгий."""
    skip = tuple(os.path.realpath(e) for e in exclude if e)
    best = {}
    for source, crt, key in _cert_candidates(root):
        if skip and os.path.realpath(crt).startswith(skip):
            continue
        info = _cert_info(crt, key)
        if not info:
            continue
        name = pub_ip if pub_ip in info["ips"] else next(
            (n for n in info["names"] if _resolves_to(n, pub_ip)), "")
        if name and (name not in best or info["expires"] > best[name][4]):
            best[name] = (name, source, crt, key, info["expires"])
    for row in sorted(best.values(), key=lambda r: -r[4]):
        print("\t".join(map(str, row)))


# ── Список изменений ──────────────────────────────────────
CL_HEAD = re.compile(r"^##\s+(v\d+(?:\.\d+){1,3})\b\s*(.*)$")


def _ver_tuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:4])


# Модуль ядра: смена API udp_tunnel (struct socket → struct sock) пришла в
# 7.1.5, и апстрим выбирает вызов по номеру версии. Ядра дистрибутивов
# переносят её в старые версии частично: в Ubuntu 7.0.0-38 setup_udp_tunnel_sock
# уже берёт struct sock, а udp_tunnel_sock_release — ещё struct socket, и
# модуль не собирается. Для ядер < 7.1.5 вызов выбирается по заголовкам.
MOD_UDP_OLD = """#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 1, 5)
#include <net/udp_tunnel.h>
#define setup_udp_tunnel_sock(net, sk, sock_cfg) setup_udp_tunnel_sock(net, sk->sk_socket, sock_cfg)
#define udp_tunnel_sock_release(sk) udp_tunnel_sock_release(sk->sk_socket)
#endif"""
MOD_UDP_NEW = """#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 1, 5)
#include <net/udp_tunnel.h>
/* awg2: перенос смены API в старые ядра — по заголовкам (compat/Kbuild.include) */
#ifndef COMPAT_UDP_TUNNEL_SETUP_SK
#define setup_udp_tunnel_sock(net, sk, sock_cfg) setup_udp_tunnel_sock(net, sk->sk_socket, sock_cfg)
#endif
#ifndef COMPAT_UDP_TUNNEL_RELEASE_SK
#define udp_tunnel_sock_release(sk) udp_tunnel_sock_release(sk->sk_socket)
#endif
#endif"""
MOD_UDP_KBUILD = """
# awg2: смена API udp_tunnel, перенесённая в ядро дистрибутива до 7.1.5.
# Без запятых и скобок в шаблоне — для ifneq они разделители («.» — любой символ)
ifneq ($(shell grep -s "setup_udp_tunnel_sock.struct net .net. struct sock .sk" "$(srctree)/include/net/udp_tunnel.h"),)
ccflags-y += -DCOMPAT_UDP_TUNNEL_SETUP_SK
endif
ifneq ($(shell grep -s "udp_tunnel_sock_release.struct sock ." "$(srctree)/include/net/udp_tunnel.h"),)
ccflags-y += -DCOMPAT_UDP_TUNNEL_RELEASE_SK
endif
"""


def cmd_mod_compat_patch(src):
    """Правка исходников модуля перед сборкой (каталог src тега). Печатает
    patched | already | skip — skip, если в теге этого места нет (апстрим
    поправил сам или переписал): тогда исходник не трогаем."""
    compat, kbuild = os.path.join(src, "compat/compat.h"), os.path.join(src, "compat/Kbuild.include")
    if not (os.path.isfile(compat) and os.path.isfile(kbuild)):
        print("skip")
        return
    text = read(compat)
    if "COMPAT_UDP_TUNNEL_SETUP_SK" in text:
        print("already")
        return
    if MOD_UDP_OLD not in text:
        print("skip")
        return
    with open(compat, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text.replace(MOD_UDP_OLD, MOD_UDP_NEW, 1))
    with open(kbuild, "a", encoding="utf-8") as f:
        f.write(MOD_UDP_KBUILD)
    print("patched")


def cmd_changelog_json(current, available=None):
    """CHANGELOG.md из stdin → разделы для экрана «Обновление»: новее
    установленной версии (сверху самая новая, не больше десяти), а если
    новее нет — раздел текущей. Заголовок раздела: «## v1.1.1 — дата (бот 3.1.0)».
    available — версия к обновлению по свежему кэшу проверки (пусто — новее нет)."""
    sections, cur = [], None
    for line in sys.stdin.read().replace("\r", "").split("\n"):
        m = CL_HEAD.match(line)
        if m:
            cur = {"version": m[1], "title": m[2].strip(" —–-"), "lines": []}
            sections.append(cur)
        elif line.startswith("## "):
            cur = None
        elif cur is not None:
            cur["lines"].append(line)
    for s in sections:
        body = "\n".join(s.pop("lines")).strip()
        s["body"] = re.sub(r"(?:\n\s*-{3,}\s*)+$", "", body).strip()[:20000]
    now = _ver_tuple(current)
    newer = sorted((s for s in sections if _ver_tuple(s["version"]) > now),
                   key=lambda s: _ver_tuple(s["version"]), reverse=True)[:10]
    shown = newer or [s for s in sections if _ver_tuple(s["version"]) == now][:1]
    out = {"current": current, "newer": bool(newer), "sections": shown}
    if available is not None:
        out["available"] = available
    print(json.dumps(out, ensure_ascii=False))


def cmd_safe_untar(archive, dest):
    """Распаковать только обычные файлы и каталоги без выхода за dest:
    архив может прийти от пользователя (бэкап, загруженный в бота)."""
    import tarfile
    root = os.path.realpath(dest)
    os.makedirs(root, exist_ok=True)
    n = 0
    try:
        tar = tarfile.open(archive, "r:*")
    except (tarfile.TarError, OSError):
        die("это не архив tar.gz")
    with tar:
        for m in tar.getmembers():
            parts = [p for p in m.name.replace("\\", "/").split("/") if p not in ("", ".")]
            if not parts or ".." in parts or not (m.isfile() or m.isdir()):
                continue
            path = os.path.join(root, *parts)
            if m.isdir():
                os.makedirs(path, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(path), exist_ok=True)
            src = tar.extractfile(m)
            with open(path, "wb") as f:
                shutil.copyfileobj(src, f)
            os.chmod(path, 0o600)
            n += 1
    if not n:
        die("в архиве нет файлов")


def cmd_web_hash():
    """Пароль веб-панели (stdin) → scrypt-хеш в формате awgbot.web.hash_password."""
    import base64
    import hashlib
    pw = sys.stdin.read()
    if not pw:
        die("пустой пароль")
    salt = os.urandom(16)
    dk = hashlib.scrypt(pw.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)
    print("scrypt$%d$%d$%d$%s$%s" % (2 ** 14, 8, 1, base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))


COMMANDS = {
    "peers": cmd_peers, "meta-set": cmd_meta_set, "peer-del": cmd_peer_del,
    "peer-rename": cmd_peer_rename, "peers-clear": cmd_peers_clear,
    "params-replace": cmd_params_replace, "keepalive-set": cmd_keepalive_set, "params-check": cmd_params_check,
    "i-replace": cmd_i_replace,
    "expire-set": cmd_expire_set, "expire-clear": cmd_expire_clear,
    "expire-check": cmd_expire_check,
    "traffic-tick": cmd_traffic_tick, "traffic-daily": cmd_traffic_daily, "traffic-now": cmd_traffic_now,
    "traffic-rows": cmd_traffic_rows, "traffic-report": cmd_traffic_report,
    "limit-set": cmd_limit_set, "limit-reset": cmd_limit_reset, "size-parse": cmd_size_parse,
    "web-hash": cmd_web_hash,
    "net-of": cmd_net_of, "pick-net": cmd_pick_net, "net-overlaps": cmd_net_overlaps,
    "allowed-except": cmd_allowed_except,
    "rand-key": cmd_rand_key, "phobos-link": cmd_phobos_link, "exit-conf-fix": cmd_exit_conf_fix,
    "conf-hooks": cmd_conf_hooks, "mod-compat-patch": cmd_mod_compat_patch,
    "xray-link": cmd_xray_link, "xray-default": cmd_xray_default, "xray-add": cmd_xray_add,
    "xray-del": cmd_xray_del, "xray-tags": cmd_xray_tags, "xray-restore-clean": cmd_xray_restore_clean, "xray-probe": cmd_xray_probe,
    "xray-probe-tag": cmd_xray_probe_tag, "xray-tun-probe": cmd_xray_tun_probe,
    "xray-test-copy": cmd_xray_test_copy,
    "xray-balancer": cmd_xray_balancer, "xray-balancer-get": cmd_xray_balancer_get,
    "xray-main": cmd_xray_main, "xray-main-get": cmd_xray_main_get,
    "xray-ru": cmd_xray_ru, "xray-prepare": cmd_xray_prepare,
    "pcap-analyze": cmd_pcap_analyze, "safe-untar": cmd_safe_untar,
    "cert-find": cmd_cert_find, "changelog-json": cmd_changelog_json,
    "json-kv": cmd_json_kv, "json-rows": cmd_json_rows, "json-list": cmd_json_list,
    "clients-json": cmd_clients_json, "api-envelope": cmd_api_envelope,
    "api-job-status": cmd_api_job_status, "api-jobs": cmd_api_jobs,
    "tg-targets": cmd_tg_targets,
}

def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        die("команда: " + ", ".join(sorted(COMMANDS)))
    # Байты не-UTF-8 из конфига (surrogateescape в read) печатаем как «?», а не падаем
    sys.stdout.reconfigure(errors="replace")
    try:
        COMMANDS[sys.argv[1]](*sys.argv[2:])
    except TypeError as e:
        die("неверные аргументы %s: %s" % (sys.argv[1], e))
    except (OSError, ValueError) as e:
        die("%s: %s" % (sys.argv[1], e))


if __name__ == "__main__":
    main()
