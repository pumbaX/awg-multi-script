"""
core.py — низкоуровневая работа с AmneziaWG.

Бот не «нажимает» пункты меню скрипта awg2, а работает с теми же файлами
и утилитами напрямую — это надёжно и не ломается при автообновлении скрипта.

Совместимость с awg2 (v6.9.x):
  • сервер:        /etc/amnezia/amneziawg/awg0.conf
  • клиент-файлы:  /root/<name>_awg2.conf
  • метка имени:   строка-комментарий "# <name>" внутри [Peer]
  • служебки:      "# expires=<ts>"  и  "# orig_ips=<ip>"  внутри [Peer]
  • интерфейс:     awg0
  • применение:    awg syncconf awg0 <(awg-quick strip awg0)
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

# Пути можно переопределить через окружение — удобно для локальной проверки
# без реального сервера (AWG_TEST_MODE подсовывает фейковый конфиг и мок awg).
SERVER_CONF = os.environ.get("AWG_SERVER_CONF", "/etc/amnezia/amneziawg/awg0.conf")
IFACE = os.environ.get("AWG_IFACE", "awg0")
CLIENT_DIR = os.environ.get("AWG_CLIENT_DIR", "/root")
SUSPEND_IP = "127.0.0.2/32"  # AllowedIPs у заблокированных по сроку (как в awg2)


# ───────────────────────── exec helpers ─────────────────────────
def run(cmd: list[str], timeout: int = 60) -> tuple[int, str, str]:
    """Запуск команды. Возвращает (rc, stdout, stderr)."""
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout: {' '.join(cmd)}"
    except FileNotFoundError:
        return 127, "", f"not found: {cmd[0]}"


def have(binary: str) -> bool:
    return shutil.which(binary) is not None


# ───────────────────────── data model ─────────────────────────
@dataclass
class Peer:
    name: str
    public_key: str = ""
    preshared_key: str = ""
    allowed_ips: str = ""
    expires: int | None = None          # unix-ts срока действия (None = бессрочно)
    orig_ips: str | None = None         # сохранённый IP, если заблокирован сроком
    note: str = ""                      # заметка (хранится в conf как # note=<b64>)
    # рантайм-статистика (из `awg show`)
    rx: int = 0                         # принято сервером от клиента (download у клиента — наоборот)
    tx: int = 0
    last_handshake: int = 0             # unix-ts, 0 = не было
    endpoint: str = ""

    @property
    def blocked(self) -> bool:
        return bool(self.orig_ips)

    @property
    def monitored(self) -> bool:
        return MONITOR_TAG.lower() in (self.note or "").lower()

    @property
    def online(self) -> bool:
        return self.last_handshake > 0 and (time.time() - self.last_handshake) < 120

    @property
    def conf_path(self) -> str:
        return os.path.join(CLIENT_DIR, f"{self.name}_awg2.conf")


@dataclass
class ServerInfo:
    installed: bool = False
    address: str = ""
    listen_port: str = ""
    mtu: str = ""
    public_ip: str = ""
    iface_up: bool = False
    profile: str = ""
    region: str = ""
    peers_count: int = 0
    extra: dict = field(default_factory=dict)


# ───────────────────────── server-conf parsing ─────────────────────────
def server_installed() -> bool:
    return Path(SERVER_CONF).is_file()


def _split_blocks(text: str) -> tuple[str, list[str]]:
    """Делит конфиг на header (до первого [Peer]) и список peer-блоков."""
    parts = re.split(r"(?=\[Peer\])", text)
    return parts[0], parts[1:]


def _public_ip_from_peers() -> str:
    """Достаём endpoint из любого клиентского файла (Endpoint = ip:port)."""
    for f in Path(CLIENT_DIR).glob("*_awg2.conf"):
        try:
            m = re.search(r"^Endpoint\s*=\s*([^:]+):", f.read_text(), re.M)
            if m:
                return m.group(1).strip()
        except OSError:
            continue
    return ""


def get_server_info() -> ServerInfo:
    info = ServerInfo()
    if not server_installed():
        return info
    info.installed = True
    text = Path(SERVER_CONF).read_text()

    if m := re.search(r"^Address\s*=\s*(.+)$", text, re.M):
        info.address = m.group(1).strip()
    if m := re.search(r"^ListenPort\s*=\s*(.+)$", text, re.M):
        info.listen_port = m.group(1).strip()
    if m := re.search(r"^MTU\s*=\s*(.+)$", text, re.M):
        info.mtu = m.group(1).strip()
    if m := re.search(r"^#\s*AWG_PROFILE=(.+)$", text, re.M):
        info.profile = m.group(1).strip()
    if m := re.search(r"^#\s*Region:\s*(.+)$", text, re.M):
        info.region = m.group(1).strip()

    _, peers = _split_blocks(text)
    info.peers_count = len(peers)

    rc, out, _ = run(["awg", "show", IFACE])
    info.iface_up = rc == 0 and bool(out.strip())
    info.public_ip = _public_ip_from_peers()
    return info


def _parse_runtime(peers: dict[str, Peer]) -> None:
    """Обогащает peers статистикой из `awg show awg0 ...` (ключ — pubkey)."""
    by_pub = {p.public_key: p for p in peers.values() if p.public_key}

    rc, out, _ = run(["awg", "show", IFACE, "transfer"])
    if rc == 0:
        for line in out.splitlines():
            cols = line.split()
            if len(cols) >= 3 and cols[0] in by_pub:
                by_pub[cols[0]].rx = int(cols[1]) if cols[1].isdigit() else 0
                by_pub[cols[0]].tx = int(cols[2]) if cols[2].isdigit() else 0

    rc, out, _ = run(["awg", "show", IFACE, "latest-handshakes"])
    if rc == 0:
        for line in out.splitlines():
            cols = line.split()
            if len(cols) >= 2 and cols[0] in by_pub:
                by_pub[cols[0]].last_handshake = int(cols[1]) if cols[1].isdigit() else 0

    rc, out, _ = run(["awg", "show", IFACE, "endpoints"])
    if rc == 0:
        for line in out.splitlines():
            cols = line.split()
            if len(cols) >= 2 and cols[0] in by_pub:
                by_pub[cols[0]].endpoint = cols[1]


def list_peers(with_runtime: bool = True) -> list[Peer]:
    if not server_installed():
        return []
    text = Path(SERVER_CONF).read_text()
    _, blocks = _split_blocks(text)
    peers: dict[str, Peer] = {}
    order: list[str] = []

    for block in blocks:
        name = ""
        expires = None
        orig_ips = None
        # имя — первый "# слово" без =. Старый "# note=" (из ранних версий)
        # игнорируем здесь — заметки теперь в отдельном файле.
        for m in re.finditer(r"^#\s+(\S.*?)\s*$", block, re.M):
            c = m.group(1).strip()
            if c.startswith("expires="):
                v = c.split("=", 1)[1]
                expires = int(v) if v.isdigit() else None
            elif c.startswith("orig_ips="):
                orig_ips = c.split("=", 1)[1] or None
            elif c.startswith("note="):
                continue  # legacy, не имя
            elif not name:
                name = c
        if not name:
            continue
        p = Peer(name=name, expires=expires, orig_ips=orig_ips,
                 note=_load_notes().get(name, ""))
        if m := re.search(r"^PublicKey\s*=\s*(\S+)", block, re.M):
            p.public_key = m.group(1)
        if m := re.search(r"^PresharedKey\s*=\s*(\S+)", block, re.M):
            p.preshared_key = m.group(1)
        if m := re.search(r"^AllowedIPs\s*=\s*(.+)$", block, re.M):
            p.allowed_ips = m.group(1).strip()
        peers[name] = p
        order.append(name)

    if with_runtime:
        _parse_runtime(peers)
    return [peers[n] for n in order]


def get_peer(name: str) -> Peer | None:
    for p in list_peers():
        if p.name == name:
            return p
    return None


# ───────────────────────── atomic conf write ─────────────────────────
def restore_backup(archive_bytes: bytes) -> tuple[bool, str]:
    """
    Восстанавливает конфиг сервера и клиентов из .tar.gz бэкапа (формат нашего
    cb_backup: awg0.conf + clients/*_awg2.conf). Перед заменой делает бэкап
    текущего состояния для отката. Возвращает (ok, сообщение).
    """
    import tarfile, io as _io, shutil, time as _t
    # 1) распаковка во временную папку с проверкой содержимого
    tmp = tempfile.mkdtemp(prefix="awg-restore.")
    try:
        try:
            with tarfile.open(fileobj=_io.BytesIO(archive_bytes), mode="r:gz") as tar:
                # безопасная распаковка: только обычные файлы, без путей наружу
                members = []
                for m in tar.getmembers():
                    if not m.isfile():
                        continue
                    name = m.name.lstrip("./")
                    if name.startswith("/") or ".." in name.split("/"):
                        continue
                    if name == "awg0.conf" or (name.startswith("clients/") and name.endswith("_awg2.conf")):
                        members.append(m)
                if not members:
                    return False, "В архиве нет awg0.conf или клиентов — это не бэкап awgToolza."
                tar.extractall(tmp, members=members)
        except (tarfile.TarError, OSError) as e:
            return False, f"Не удалось распаковать архив: {e}"

        new_server = os.path.join(tmp, "awg0.conf")
        if not os.path.isfile(new_server):
            return False, "В архиве нет серверного конфига awg0.conf."

        # 2) бэкап текущего состояния (для отката)
        bak = f"/var/lib/awg-bot/restore-rollback-{int(_t.time())}"
        os.makedirs(bak, exist_ok=True)
        if os.path.isfile(SERVER_CONF):
            shutil.copy2(SERVER_CONF, os.path.join(bak, "awg0.conf"))

        # 3) применяем: серверный конфиг
        new_text = open(new_server, encoding="utf-8").read()
        _write_conf_atomic(new_text)

        # 4) клиенты
        cli_dir = os.path.join(tmp, "clients")
        restored = 0
        if os.path.isdir(cli_dir):
            for f in os.listdir(cli_dir):
                if f.endswith("_awg2.conf"):
                    shutil.copy2(os.path.join(cli_dir, f), os.path.join(CLIENT_DIR, f))
                    os.chmod(os.path.join(CLIENT_DIR, f), 0o600)
                    restored += 1

        # 5) применяем конфиг к интерфейсу
        ok, msg = apply_syncconf()
        if not ok:
            # откат серверного конфига
            if os.path.isfile(os.path.join(bak, "awg0.conf")):
                _write_conf_atomic(open(os.path.join(bak, "awg0.conf")).read())
                apply_syncconf()
            return False, f"Конфиг не применился, откатил назад. {msg}"

        peers = len(list_peers(with_runtime=False))
        return True, (f"Восстановлено: сервер + {restored} клиентских конфигов. "
                      f"Активно пиров: {peers}. {msg}")
    finally:
        try:
            import shutil as _sh
            _sh.rmtree(tmp, ignore_errors=True)
        except Exception:
            pass


def _write_conf_atomic(text: str) -> None:
    d = os.path.dirname(SERVER_CONF)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".awg0.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, SERVER_CONF)


def apply_syncconf() -> tuple[bool, str]:
    """Применяет конфиг без обрыва туннеля (как awg2 _expire_apply)."""
    if not have("awg") or not have("awg-quick"):
        return False, "awg/awg-quick не найдены"
    # awg-quick strip отдаёт «чистый» конфиг для syncconf
    rc, stripped, err = run(["awg-quick", "strip", IFACE])
    if rc != 0:
        # запасной путь — рестарт интерфейса
        return restart_iface()
    fd, tmp = tempfile.mkstemp(prefix="awgsync.", suffix=".conf")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(stripped)
        rc, _, err = run(["awg", "syncconf", IFACE, tmp])
        if rc == 0:
            return True, "Конфиг применён (syncconf)"
        return restart_iface()
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def restart_iface() -> tuple[bool, str]:
    run(["awg-quick", "down", SERVER_CONF])
    rc, _, err = run(["awg-quick", "up", SERVER_CONF])
    if rc == 0:
        return True, "Интерфейс awg0 перезапущен"
    return False, f"Не удалось поднять awg0: {err.strip()}"


# ───────────────────────── client add / delete / rename ─────────────────────────
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def _find_free_ip(base_ip: str) -> str | None:
    """Первый свободный X.X.X.N (2..254), не занятый peer'ом и не адрес сервера."""
    used = set()
    text = Path(SERVER_CONF).read_text()
    for m in re.finditer(r"^(?:AllowedIPs|Address)\s*=\s*([\d.]+)/", text, re.M):
        used.add(m.group(1))
    srv_oct = None
    if m := re.search(r"^Address\s*=\s*[\d.]+\.(\d+)/", text, re.M):
        srv_oct = m.group(1)
    for n in range(2, 255):
        ip = f"{base_ip}.{n}"
        if ip in used:
            continue
        if srv_oct and str(n) == srv_oct:
            continue
        return ip
    return None


def add_client(name: str, expires: int | None = None,
               profile: str = "", domain: str = "") -> tuple[bool, str, str | None]:
    """
    Создаёт клиента в формате awg2. Возвращает (ok, message, conf_path|None).
    profile — мимикрия CPS (tls/dns/sip/quic/basic/''); '' или 'basic' = без I1.
    """
    if not server_installed():
        return False, "Сервер не установлен", None
    if not have("awg"):
        return False, "awg не найден", None
    if not NAME_RE.match(name):
        return False, "Имя: только A-Z a-z 0-9 _ -", None
    if get_peer(name):
        return False, f"Клиент '{name}' уже существует", None

    text = Path(SERVER_CONF).read_text()
    m = re.search(r"^Address\s*=\s*([\d.]+)/", text, re.M)
    if not m:
        return False, "Не нашёл Address в конфиге сервера", None
    base_ip = ".".join(m.group(1).split(".")[:3])
    client_ip = _find_free_ip(base_ip)
    if not client_ip:
        return False, "Подсеть заполнена — нет свободных IP", None

    # серверные параметры
    srv_priv_pub = re.search(r"^PrivateKey\s*=\s*(\S+)", text, re.M)
    if not srv_priv_pub:
        return False, "Не нашёл PrivateKey сервера", None
    rc, srv_pub, _ = run(["bash", "-c", f"echo {srv_priv_pub.group(1)} | awg pubkey"])
    srv_pub = srv_pub.strip()

    lp_m = re.search(r"^ListenPort\s*=\s*(\S+)", text, re.M)
    listen_port = lp_m.group(1) if lp_m else ""
    mtu_m = re.search(r"^MTU\s*=\s*(\S+)", text, re.M)
    mtu = mtu_m.group(1) if mtu_m else "1320"

    # AWG-параметры (Jc, Jmin, ... S1, H1) копируем из [Interface] сервера
    iface_block = _split_blocks(text)[0]
    awg_params = []
    for key in ("Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4",
                "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5",
                "Itime", "T1", "T2", "T3", "T4", "T5"):
        km = re.search(rf"^{key}\s*=\s*(.+)$", iface_block, re.M)
        if km:
            awg_params.append(f"{key} = {km.group(1).strip()}")

    public_ip = _public_ip_from_peers() or get_server_info().public_ip
    if not public_ip:
        rc, out, _ = run(["bash", "-c", "curl -s --max-time 5 https://api.ipify.org || true"])
        public_ip = out.strip()
    if not public_ip:
        return False, "Не удалось определить внешний IP сервера", None

    # генерация клиентских ключей
    rc, cli_priv, _ = run(["awg", "genkey"])
    cli_priv = cli_priv.strip()
    rc, cli_pub, _ = run(["bash", "-c", f"echo {cli_priv} | awg pubkey"])
    cli_pub = cli_pub.strip()
    rc, psk, _ = run(["awg", "genpsk"])
    psk = psk.strip()
    if not (cli_priv and cli_pub and psk):
        return False, "Сбой генерации ключей (awg genkey/genpsk)", None

    dns_m = None
    for f in Path(CLIENT_DIR).glob("*_awg2.conf"):
        dm = re.search(r"^DNS\s*=\s*(.+)$", f.read_text(), re.M)
        if dm:
            dns_m = dm.group(1).strip()
            break
    client_dns = dns_m or "1.1.1.1, 1.0.0.1"

    # ── добавляем peer в серверный конфиг ──
    peer_lines = [
        "",
        "[Peer]",
        f"# {name}",
    ]
    if expires:
        peer_lines.append(f"# expires={expires}")
    peer_lines += [
        f"PublicKey = {cli_pub}",
        f"PresharedKey = {psk}",
        f"AllowedIPs = {client_ip}/32",
    ]
    new_text = text.rstrip() + "\n" + "\n".join(peer_lines) + "\n"
    _write_conf_atomic(new_text)

    # ── клиентский конфиг ──
    cli_lines = [
        "[Interface]",
        f"PrivateKey = {cli_priv}",
        f"Address = {client_ip}/32",
        f"DNS = {client_dns}",
        f"MTU = {mtu}",
    ]
    cli_lines += awg_params
    # I1-мимикрия по выбранному профилю (генерируется тем же кодом, что в awg2).
    # I1 — клиентский параметр, в серверный конфиг не пишется.
    note_profile = ""
    if profile and profile != "basic":
        from . import cps
        i1 = cps.gen_i1(profile, domain)
        if i1:
            # не дублируем, если awg_params уже принёс I1 откуда-то
            if not any(l.startswith("I1 ") or l.startswith("I1=") for l in cli_lines):
                cli_lines.append(f"I1 = {i1}")
                note_profile = profile
        else:
            note_profile = "basic (генерация I1 не удалась)"
    cli_lines += [
        "",
        "[Peer]",
        f"PublicKey = {srv_pub}",
        f"PresharedKey = {psk}",
        f"Endpoint = {public_ip}:{listen_port}",
        "AllowedIPs = 0.0.0.0/0, ::/0",
        "PersistentKeepalive = 25",
    ]
    conf_path = os.path.join(CLIENT_DIR, f"{name}_awg2.conf")
    Path(conf_path).write_text("\n".join(cli_lines) + "\n")
    os.chmod(conf_path, 0o600)

    ok, msg = apply_syncconf()
    prof_suffix = f" Профиль: {note_profile}." if note_profile else ""
    return True, ("Клиент создан." + prof_suffix + " " + msg), conf_path


def delete_client(name: str) -> tuple[bool, str]:
    if not server_installed():
        return False, "Сервер не установлен"
    text = Path(SERVER_CONF).read_text()
    header, blocks = _split_blocks(text)
    kept = []
    removed = False
    for block in blocks:
        m = re.search(r"^#\s+(\S.*?)\s*$", block, re.M)
        # имя — первый коммент, не expires=/orig_ips=
        nm = None
        for cm in re.finditer(r"^#\s+(\S.*?)\s*$", block, re.M):
            c = cm.group(1).strip()
            if not c.startswith(("expires=", "orig_ips=", "note=")):
                nm = c
                break
        if nm == name:
            removed = True
            continue
        kept.append(block)
    if not removed:
        return False, f"Клиент '{name}' не найден"
    _write_conf_atomic(header + "".join(kept))
    cli = os.path.join(CLIENT_DIR, f"{name}_awg2.conf")
    if os.path.isfile(cli):
        try:
            os.unlink(cli)
        except OSError:
            pass
    ok, msg = apply_syncconf()
    _delete_note(name)
    return True, f"Клиент '{name}' удалён. {msg}"


def rename_client(old: str, new: str) -> tuple[bool, str]:
    if not NAME_RE.match(new):
        return False, "Новое имя: только A-Z a-z 0-9 _ -"
    if get_peer(new):
        return False, f"Имя '{new}' уже занято"
    p = get_peer(old)
    if not p:
        return False, f"Клиент '{old}' не найден"

    text = Path(SERVER_CONF).read_text()
    header, blocks = _split_blocks(text)
    out_blocks = []
    for block in blocks:
        nm = None
        for cm in re.finditer(r"^#\s+(\S.*?)\s*$", block, re.M):
            c = cm.group(1).strip()
            if not c.startswith(("expires=", "orig_ips=", "note=")):
                nm = c
                break
        if nm == old:
            block = re.sub(rf"^#\s+{re.escape(old)}\s*$", f"# {new}", block, count=1, flags=re.M)
        out_blocks.append(block)
    _write_conf_atomic(header + "".join(out_blocks))

    old_f = os.path.join(CLIENT_DIR, f"{old}_awg2.conf")
    new_f = os.path.join(CLIENT_DIR, f"{new}_awg2.conf")
    if os.path.isfile(old_f):
        os.rename(old_f, new_f)
    _rename_note(old, new)
    return True, f"'{old}' → '{new}'"


# ───────────────────────── expire (сроки действия) ─────────────────────────
def _set_peer_comment(name: str, key: str, value: str | None) -> bool:
    """
    Устанавливает/удаляет служебный комментарий "# key=value" в peer-блоке.
    value=None — удалить строку.
    """
    text = Path(SERVER_CONF).read_text()
    header, blocks = _split_blocks(text)
    changed = False
    out = []
    for block in blocks:
        nm = None
        for cm in re.finditer(r"^#\s+(\S.*?)\s*$", block, re.M):
            c = cm.group(1).strip()
            if not c.startswith(("expires=", "orig_ips=", "note=")):
                nm = c
                break
        if nm == name:
            block = re.sub(rf"^#\s*{key}=.*$\n?", "", block, flags=re.M)
            if value is not None:
                # вставляем сразу после строки имени "# name"
                block = re.sub(
                    rf"(^#\s+{re.escape(name)}\s*$)",
                    rf"\1\n# {key}={value}",
                    block, count=1, flags=re.M,
                )
            changed = True
        out.append(block)
    if changed:
        _write_conf_atomic(header + "".join(out))
    return changed


def set_expire(name: str, ts: int) -> tuple[bool, str]:
    if not get_peer(name):
        return False, f"Клиент '{name}' не найден"
    _set_peer_comment(name, "expires", str(ts))
    apply_syncconf()
    return True, f"Срок установлен: {datetime.fromtimestamp(ts):%Y-%m-%d %H:%M}"


def clear_expire(name: str) -> tuple[bool, str]:
    p = get_peer(name)
    if not p:
        return False, f"Клиент '{name}' не найден"
    # если был заблокирован — вернуть оригинальный IP
    if p.orig_ips:
        _restore_allowed_ip(name, p.orig_ips)
    _set_peer_comment(name, "expires", None)
    _set_peer_comment(name, "orig_ips", None)
    apply_syncconf()
    return True, f"Срок снят: '{name}' теперь бессрочный"


def _restore_allowed_ip(name: str, orig: str) -> None:
    text = Path(SERVER_CONF).read_text()
    header, blocks = _split_blocks(text)
    out = []
    for block in blocks:
        nm = None
        for cm in re.finditer(r"^#\s+(\S.*?)\s*$", block, re.M):
            c = cm.group(1).strip()
            if not c.startswith(("expires=", "orig_ips=", "note=")):
                nm = c
                break
        if nm == name:
            block = re.sub(r"^AllowedIPs\s*=\s*.+$", f"AllowedIPs = {orig}", block, count=1, flags=re.M)
        out.append(block)
    _write_conf_atomic(header + "".join(out))


def parse_duration(spec: str) -> int | None:
    """'1h','1d','7d','30d' или 'YYYY-MM-DD HH:MM' → unix-ts."""
    spec = spec.strip()
    m = re.fullmatch(r"(\d+)([hdwm])", spec)
    if m:
        n = int(m.group(1))
        unit = {"h": 3600, "d": 86400, "w": 604800, "m": 2592000}[m.group(2)]
        return int(time.time()) + n * unit
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return int(datetime.strptime(spec, fmt).timestamp())
        except ValueError:
            continue
    return None


# ───────────────────────── formatting ─────────────────────────
def fmt_bytes(n: int) -> str:
    if n >= 1073741824:
        return f"{n/1073741824:.2f} GiB"
    if n >= 1048576:
        return f"{n/1048576:.2f} MiB"
    if n >= 1024:
        return f"{n/1024:.1f} KiB"
    return f"{n} B"


def fmt_ago(ts: int) -> str:
    if not ts:
        return "никогда"
    d = int(time.time()) - ts
    if d < 60:
        return f"{d} с назад"
    if d < 3600:
        return f"{d//60} мин назад"
    if d < 86400:
        return f"{d//3600} ч назад"
    return f"{d//86400} дн назад"


def fmt_uptime(seconds: int) -> str:
    """Человекочитаемый аптайм: '3д 4ч', '5ч 12м', '8м'."""
    if seconds <= 0:
        return "—"
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}д {h}ч"
    if h:
        return f"{h}ч {m}м"
    return f"{m}м"


# ───────────────────────── версии (бот и awg2) ─────────────────────────
REPO_RAW = "https://raw.githubusercontent.com/pumbaX/awg-multi-script/main"
AWG2_BIN_PATH = "/usr/local/bin/awg2"


def bot_version_local() -> str:
    """Версия установленного бота (из awgbot/__init__.py)."""
    try:
        from . import __version__
        return __version__
    except Exception:
        return "?"


def _grep_version(text: str) -> str:
    # ищем __version__ = "x.y.z" или VERSION="x.y.z"
    m = re.search(r'__version__\s*=\s*["\']([^"\']+)["\']', text)
    if m:
        return m.group(1)
    m = re.search(r'VERSION\s*=\s*["\']?v?([0-9][0-9.]*)["\']?', text)
    return m.group(1) if m else "?"


def awg2_version_local() -> str:
    """Версия установленного awg2 (из шапки скрипта)."""
    try:
        text = open(AWG2_BIN_PATH, encoding="utf-8", errors="replace").read(8000)
    except OSError:
        return "не установлен"
    # awg2 обычно содержит строку вида: SCRIPT_VERSION="6.9.3" или v6.9.3
    m = re.search(r'(?:SCRIPT_)?VERSION\s*=\s*["\']?v?([0-9][0-9.]*)', text)
    if m:
        return m.group(1)
    m = re.search(r'AwgToolza\s+v?([0-9][0-9.]+)', text)
    return m.group(1) if m else "?"


def _fetch(url: str, timeout: int = 10) -> str | None:
    """Тянет текст по URL через curl (без внешних зависимостей)."""
    rc, out, _ = run(["curl", "-fsSL", "--max-time", str(timeout), url], timeout=timeout + 5)
    return out if rc == 0 and out.strip() else None


def bot_version_remote() -> str:
    txt = _fetch(f"{REPO_RAW}/awg_bot/awgbot/__init__.py")
    return _grep_version(txt) if txt else "?"


def awg2_version_remote() -> str:
    # читаем только начало awg2.sh, версия в шапке
    txt = _fetch(f"{REPO_RAW}/awg2.sh")
    if not txt:
        return "?"
    m = re.search(r'(?:SCRIPT_)?VERSION\s*=\s*["\']?v?([0-9][0-9.]*)', txt[:8000])
    if m:
        return m.group(1)
    m = re.search(r'AwgToolza\s+v?([0-9][0-9.]+)', txt[:8000])
    return m.group(1) if m else "?"


def server_uptime() -> int:
    """
    Время работы интерфейса awg0 в секундах.
    Берём из systemd (awg-quick@awg0), иначе по возрасту /sys или статам.
    0 = не определить / не запущен.
    """
    if not server_installed():
        return 0
    # 1) systemd: ActiveEnterTimestampMonotonic точный, но проще — ActiveEnterTimestamp
    for unit in (f"awg-quick@{IFACE}.service", f"awg-quick@{IFACE}"):
        rc, out, _ = run(["systemctl", "show", unit,
                          "--property=ActiveEnterTimestampMonotonic", "--value"])
        if rc == 0 and out.strip().isdigit():
            mono_us = int(out.strip())
            if mono_us > 0:
                # текущее монотонное время из /proc/uptime
                try:
                    up = float(open("/proc/uptime").read().split()[0])
                    started_ago = up - mono_us / 1_000_000
                    if started_ago >= 0:
                        return int(started_ago)
                except (OSError, ValueError):
                    pass
    # 2) запасной путь: возраст файла-стейта интерфейса
    for path in (f"/sys/class/net/{IFACE}", f"/var/run/wireguard/{IFACE}.name"):
        try:
            return int(time.time() - os.path.getmtime(path))
        except OSError:
            continue
    return 0


# ───────────────────────── заметки клиентов ─────────────────────────
# ВАЖНО: заметки хранятся в отдельном файле бота, НЕ в awg0.conf.
# Причина: awg2 определяет имя клиента по строке-комментарию "# ..." и
# пропускает только "expires="/"orig_ips=". Строку "# note=..." он принял бы
# за имя — клиент отображался бы в awg2 как "note=...". Поэтому держим заметки
# у себя: ключ — имя клиента, значение — текст.
MONITOR_TAG = "#ping"
NOTES_FILE = os.environ.get("AWG_NOTES_FILE", "/var/lib/awg-bot/notes.json")


def _load_notes() -> dict:
    try:
        import json
        return json.loads(Path(NOTES_FILE).read_text())
    except Exception:
        return {}


def _save_notes(d: dict) -> None:
    import json
    try:
        Path(NOTES_FILE).parent.mkdir(parents=True, exist_ok=True)
        Path(NOTES_FILE).write_text(json.dumps(d, ensure_ascii=False))
    except OSError:
        pass


def get_note(name: str) -> str:
    """Текст заметки клиента (или пустая строка)."""
    return _load_notes().get(name, "")


def set_note(name: str, note: str) -> tuple[bool, str]:
    if not get_peer(name):
        return False, f"Клиент '{name}' не найден"
    note = note.strip()[:200]
    notes = _load_notes()
    if note:
        notes[name] = note
    else:
        notes.pop(name, None)
    _save_notes(notes)
    return True, "Заметка сохранена" if note else "Заметка очищена"


def _rename_note(old: str, new: str) -> None:
    notes = _load_notes()
    if old in notes:
        notes[new] = notes.pop(old)
        _save_notes(notes)


def _delete_note(name: str) -> None:
    notes = _load_notes()
    if name in notes:
        notes.pop(name, None)
        _save_notes(notes)


def enforce_expirations() -> list[str]:
    """
    Блокирует клиентов с истёкшим сроком (как awg2-expire.timer): меняет
    AllowedIPs на заглушку, сохраняя оригинал в '# orig_ips='. Совместимо
    с awg2 по формату. Возвращает список имён, заблокированных в этот вызов.
    Разблокировку (возврат orig_ips) делает clear_expire при снятии срока.
    """
    if not server_installed():
        return []
    now = int(time.time())
    newly = []
    for p in list_peers(with_runtime=False):
        if p.expires and p.expires <= now and not p.orig_ips:
            # сохраняем оригинальный IP и подменяем на заглушку
            _set_peer_comment(p.name, "orig_ips", p.allowed_ips)
            _replace_allowed_ip(p.name, SUSPEND_IP)
            newly.append(p.name)
    if newly:
        apply_syncconf()
    return newly


def _replace_allowed_ip(name: str, new_ip: str) -> None:
    text = Path(SERVER_CONF).read_text()
    header, blocks = _split_blocks(text)
    out = []
    for block in blocks:
        nm = None
        for cm in re.finditer(r"^#\s+(\S.*?)\s*$", block, re.M):
            c = cm.group(1).strip()
            if not c.startswith(("expires=", "orig_ips=", "note=")):
                nm = c
                break
        if nm == name:
            block = re.sub(r"^AllowedIPs\s*=\s*.+$", f"AllowedIPs = {new_ip}",
                           block, count=1, flags=re.M)
        out.append(block)
    _write_conf_atomic(header + "".join(out))


def cleanup_legacy_notes() -> int:
    """
    Убирает из awg0.conf legacy-строки '# note=...', которые ранние версии
    бота писали в конфиг (из-за них awg2 показывал клиента как 'note=...').
    Заметки при этом сохраняются — они уже в notes.json. Возвращает число
    вычищенных строк. Безопасно вызывать при каждом старте.
    """
    if not server_installed():
        return 0
    text = Path(SERVER_CONF).read_text()
    new = re.sub(r"^#\s*note=.*\n", "", text, flags=re.M)
    if new != text:
        _write_conf_atomic(new)
        apply_syncconf()
        return text.count("\n# note=") + (1 if text.startswith("# note=") else 0)
    return 0


def is_monitored(name: str) -> bool:
    return MONITOR_TAG.lower() in get_note(name).lower()



# ───────────────────────── DNSCrypt upstream (серверный шифрованный DNS) ─────────────────────────
# В awg2 «выбор DNS» = смена upstream-резолверов dnscrypt-proxy на сервере
# (server_names в dnscrypt-proxy.toml), НЕ правка DNS в конфигах клиентов.
# Для фильтрующих резолверов (yandex-safe) нужно require_nofilter = false.
DNSCRYPT_CONF = "/etc/dnscrypt-proxy/dnscrypt-proxy.toml"

# ключ -> (подпись, server_names, need_nofilter)
DNS_UPSTREAMS = {
    "default":    ("Cloudflare+Google+Cisco (реком.)", "['cloudflare', 'google', 'cisco-doh']", True),
    "cloudflare": ("Только Cloudflare", "['cloudflare']", True),
    "yandex":     ("Yandex Safe (без РКН)", "['yandex-safe']", False),
    "cisco":      ("Только Cisco (OpenDNS)", "['cisco-doh']", True),
    "google":     ("Только Google", "['google']", True),
}


def dnscrypt_installed() -> bool:
    return os.path.isfile(DNSCRYPT_CONF)


def get_dns_upstream() -> str:
    """Текущий server_names из dnscrypt-proxy.toml."""
    if not dnscrypt_installed():
        return ""
    m = re.search(r"^server_names\s*=\s*(.+)$", Path(DNSCRYPT_CONF).read_text(), re.M)
    return m.group(1).strip() if m else ""


def set_dns_upstream(key: str) -> tuple[bool, str]:
    """Меняет upstream DNSCrypt и перезапускает сервис (как awg2)."""
    if not dnscrypt_installed():
        return False, "Шифрованный DNS не установлен. Сначала установи DNS."
    preset = DNS_UPSTREAMS.get(key)
    if not preset:
        return False, "Неизвестный пресет DNS"
    label, servers, need_nofilter = preset
    text = Path(DNSCRYPT_CONF).read_text()

    nf_val = "true" if need_nofilter else "false"
    if re.search(r"^require_nofilter\s*=", text, re.M):
        text = re.sub(r"^require_nofilter\s*=.*$", f"require_nofilter = {nf_val}",
                      text, count=1, flags=re.M)
    if re.search(r"^server_names\s*=", text, re.M):
        text = re.sub(r"^server_names\s*=.*$", f"server_names = {servers}",
                      text, count=1, flags=re.M)
    else:
        return False, "В конфиге нет server_names — нестандартный dnscrypt"
    Path(DNSCRYPT_CONF).write_text(text)

    rc, _, _ = run(["systemctl", "restart", "dnscrypt-proxy.service"])
    if rc != 0:
        run(["systemctl", "restart", "dnscrypt-proxy"])
    _, out, _ = run(["systemctl", "is-active", "dnscrypt-proxy.service"])
    _, out3, _ = run(["systemctl", "is-active", "dnscrypt-proxy"])
    _, out4, _ = run(["systemctl", "is-active", "dnscrypt-proxy.socket"])
    if "active" in (out + out3 + out4):
        return True, f"Upstream → {label}"
    return False, (f"Upstream записан ({label}), но сервис не активен. "
                   "Проверь: journalctl -u dnscrypt-proxy -n 20")


# ───────────────────────── WARP на клиента (split-tunnel) ─────────────────────────
# Повторяем механику awg2: список IP в peers.list + policy routing
# `ip rule from <ip> lookup 200`. Меняем только правило конкретного клиента.
WARP_DIR = "/etc/wgcf"
WARP_PEERS = os.path.join(WARP_DIR, "peers.list")
WARP_IFACE = "warp0"
WARP_TABLE = "200"


def warp_installed() -> bool:
    return os.path.isfile("/etc/wireguard/warp0.conf")


def warp_iface_up() -> bool:
    rc, _, _ = run(["ip", "link", "show", WARP_IFACE])
    return rc == 0


def _warp_peers_set() -> set[str]:
    try:
        return {l.strip() for l in Path(WARP_PEERS).read_text().splitlines() if l.strip()}
    except OSError:
        return set()


def warp_peer_enabled(client_ip: str) -> bool:
    return client_ip in _warp_peers_set()


def _peer_ip_only(p: "Peer") -> str:
    """Чистый IP клиента из AllowedIPs (10.x.x.x/32 → 10.x.x.x)."""
    return p.allowed_ips.split("/")[0].split(",")[0].strip()


def warp_enable_client(name: str) -> tuple[bool, str]:
    p = get_peer(name)
    if not p:
        return False, f"Клиент '{name}' не найден"
    if not warp_installed():
        return False, "WARP не установлен. Сначала установи WARP."
    ip = _peer_ip_only(p)
    os.makedirs(WARP_DIR, exist_ok=True)
    peers = _warp_peers_set()
    peers.add(ip)
    Path(WARP_PEERS).write_text("\n".join(sorted(peers)) + "\n")
    if warp_iface_up():
        run(["ip", "rule", "del", "from", ip, "lookup", WARP_TABLE])
        rc, _, err = run(["ip", "rule", "add", "from", ip, "lookup", WARP_TABLE])
        if rc != 0:
            return False, f"Не удалось применить правило: {err.strip()}"
        return True, f"'{name}' ({ip}) → через WARP ☁"
    return True, f"'{name}' добавлен в WARP (применится при старте warp0)"


def warp_disable_client(name: str) -> tuple[bool, str]:
    p = get_peer(name)
    if not p:
        return False, f"Клиент '{name}' не найден"
    ip = _peer_ip_only(p)
    peers = _warp_peers_set()
    if ip in peers:
        peers.discard(ip)
        Path(WARP_PEERS).write_text(("\n".join(sorted(peers)) + "\n") if peers else "")
    if warp_iface_up():
        run(["ip", "rule", "del", "from", ip, "lookup", WARP_TABLE])
    return True, f"'{name}' ({ip}) → напрямую"


def warp_client_state(name: str) -> bool | None:
    """True=через WARP, False=напрямую, None=WARP не установлен."""
    if not warp_installed():
        return None
    p = get_peer(name)
    if not p:
        return None
    return warp_peer_enabled(_peer_ip_only(p))


# ───────────────────────── статусы WARP / DNS (прямое чтение) ─────────────────────────
def warp_status() -> str:
    """Читаем состояние WARP напрямую, без захода в меню awg2."""
    lines = []
    conf = "/etc/wireguard/warp0.conf"
    if not os.path.isfile(conf):
        return "WARP не установлен (нет warp0.conf)."
    lines.append("WARP установлен.")
    rc, out, _ = run(["wg", "show", "warp0"]) if have("wg") else (1, "", "")
    if rc == 0 and out.strip():
        lines.append("Интерфейс warp0: 🟢 поднят")
        m = re.search(r"latest handshake:\s*(.+)", out)
        if m:
            lines.append(f"Последний handshake: {m.group(1).strip()}")
    else:
        # пробуем через awg/ip
        rc2, out2, _ = run(["ip", "link", "show", "warp0"])
        lines.append("Интерфейс warp0: " + ("🟢 есть" if rc2 == 0 else "🔴 не поднят"))
    return "\n".join(lines)


def warp_hard_restart() -> tuple[bool, str]:
    """Жёсткий перезапуск WARP без pexpect: down → parse conf → up."""
    WARP_CONF  = "/etc/wireguard/warp0.conf"
    WARP_STATE = "/etc/wgcf/state"
    WARP_TABLE = "200"

    if not os.path.isfile(WARP_CONF):
        return False, "WARP не установлен (нет warp0.conf)"

    log: list[str] = []

    # ── 1. DOWN ───────────────────────────────────────────────
    client_net, iface = "", ""
    if os.path.isfile(WARP_STATE):
        for line in Path(WARP_STATE).read_text().splitlines():
            if line.startswith("client_net="):
                client_net = line.split("=", 1)[1].strip()
            elif line.startswith("iface="):
                iface = line.split("=", 1)[1].strip()

    for ip in _warp_peers_set():
        run(["ip", "rule", "del", "from", ip, "lookup", WARP_TABLE])
    if client_net:
        run(["ip", "rule", "del", "from", client_net, "lookup", WARP_TABLE])
        run(["ip", "rule", "del", "from", client_net, "table",  WARP_TABLE])
    run(["ip", "route", "flush", "table", WARP_TABLE])

    if client_net:
        run(["iptables", "-t", "nat", "-D", "POSTROUTING", "-s", client_net, "-o", "warp0", "-j", "MASQUERADE"])
        run(["iptables", "-D", "FORWARD", "-i", "awg0", "-o", "warp0", "-j", "ACCEPT"])
        run(["iptables", "-D", "FORWARD", "-i", "warp0", "-o", "awg0", "-j", "ACCEPT"])
        if iface:
            rc, _, _ = run(["iptables", "-t", "nat", "-C", "POSTROUTING", "-s", client_net, "-o", iface, "-j", "MASQUERADE"])
            if rc != 0:
                run(["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", client_net, "-o", iface, "-j", "MASQUERADE"])

    rc_del, _, _ = run(["ip", "link", "delete", "warp0"])
    log.append("warp0 снят" if rc_del == 0 else "warp0 уже отсутствовал")
    try:
        Path(WARP_STATE).unlink(missing_ok=True)
    except Exception:
        pass

    # ── 2. Парсим конфиг ─────────────────────────────────────
    def _field(key: str, text: str) -> str:
        m = re.search(rf"^{key}\s*=\s*(.+)$", text, re.MULTILINE)
        return m.group(1).strip() if m else ""

    conf_text = Path(WARP_CONF).read_text()
    warp_priv = _field("PrivateKey", conf_text)
    warp_pub  = _field("PublicKey",  conf_text)
    warp_ep   = _field("Endpoint",   conf_text)
    warp_mtu  = _field("MTU",        conf_text) or "1280"
    addr_line = _field("Address",    conf_text)
    warp_addr4 = next((p.strip() for p in addr_line.split(",") if "." in p and ":" not in p), "")

    if not all([warp_priv, warp_pub, warp_ep, warp_addr4]):
        return False, f"Не удалось распарсить warp0.conf (priv={bool(warp_priv)} pub={bool(warp_pub)} ep={bool(warp_ep)} addr={bool(warp_addr4)})"

    # AWG client_net из wg show или /etc/wireguard/awg0.conf
    client_net = ""
    rc, awg_dump, _ = run(["wg", "show", "awg0", "allowed-ips"]) if have("wg") else (1, "", "")
    if rc == 0 and awg_dump.strip():
        for line in awg_dump.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                for n in parts[1].split(","):
                    n = n.strip()
                    if n and "/" in n and "." in n and not n.startswith("0.0.0.0"):
                        client_net = n; break
            if client_net:
                break
    if not client_net:
        awg_conf = "/etc/wireguard/awg0.conf"
        if os.path.isfile(awg_conf):
            m = re.search(r"Address\s*=\s*([\d./]+)", Path(awg_conf).read_text())
            client_net = m.group(1) if m else "10.0.0.0/24"
        else:
            client_net = "10.0.0.0/24"

    # WAN iface
    _, rt_out, _ = run(["ip", "route"])
    iface = "eth0"
    for line in rt_out.splitlines():
        if line.startswith("default") and "dev" in line:
            parts = line.split()
            iface = parts[parts.index("dev") + 1]
            break

    # ── 3. UP ─────────────────────────────────────────────────
    rc, _, err = run(["ip", "link", "add", "dev", "warp0", "type", "wireguard"])
    if rc != 0:
        return False, f"Не удалось создать warp0: {err.strip()}"

    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as tf:
        tf.write(f"[Interface]\nPrivateKey = {warp_priv}\n\n[Peer]\nPublicKey = {warp_pub}\nAllowedIPs = 0.0.0.0/0\nEndpoint = {warp_ep}\n")
        tmp_path = tf.name

    rc, _, err = run(["wg", "setconf", "warp0", tmp_path])
    Path(tmp_path).unlink(missing_ok=True)
    if rc != 0:
        run(["ip", "link", "delete", "warp0"])
        return False, f"wg setconf failed: {err.strip()}"

    run(["ip", "-4", "address", "add", warp_addr4, "dev", "warp0"])
    rc, _, err = run(["ip", "link", "set", "mtu", warp_mtu, "up", "dev", "warp0"])
    if rc != 0:
        run(["ip", "link", "delete", "warp0"])
        return False, f"ip link set up failed: {err.strip()}"

    log.append("warp0 поднят")

    # iptables + policy routing
    rc, _, _ = run(["iptables", "-t", "nat", "-C", "POSTROUTING", "-s", client_net, "-o", iface, "-j", "MASQUERADE"])
    if rc != 0:
        run(["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", client_net, "-o", iface, "-j", "MASQUERADE"])

    rc, _, _ = run(["iptables", "-t", "nat", "-C", "POSTROUTING", "-s", client_net, "-o", "warp0", "-j", "MASQUERADE"])
    if rc != 0:
        run(["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", client_net, "-o", "warp0", "-j", "MASQUERADE"])

    rc, _, _ = run(["iptables", "-C", "FORWARD", "-i", "awg0", "-o", "warp0", "-j", "ACCEPT"])
    if rc != 0:
        run(["iptables", "-A", "FORWARD", "-i", "awg0", "-o", "warp0", "-j", "ACCEPT"])

    rc, _, _ = run(["iptables", "-C", "FORWARD", "-i", "warp0", "-o", "awg0", "-j", "ACCEPT"])
    if rc != 0:
        run(["iptables", "-A", "FORWARD", "-i", "warp0", "-o", "awg0", "-j", "ACCEPT"])

    run(["sysctl", "-w", "net.ipv4.conf.warp0.rp_filter=2"])
    run(["sysctl", "-w", "net.ipv4.conf.awg0.rp_filter=2"])

    run(["ip", "route", "flush", "table", WARP_TABLE])
    run(["ip", "route", "add", "default", "dev", "warp0", "src", warp_addr4.split("/")[0], "table", WARP_TABLE])

    # ip rules для всех клиентов из peers.list
    peer_count = 0
    for ip in _warp_peers_set():
        run(["ip", "rule", "del", "from", ip, "lookup", WARP_TABLE])
        rc, _, _ = run(["ip", "rule", "add", "from", ip, "lookup", WARP_TABLE])
        if rc == 0:
            peer_count += 1

    # Сохраняем state
    os.makedirs("/etc/wgcf", exist_ok=True)
    Path(WARP_STATE).write_text(f"active\nclient_net={client_net}\niface={iface}\n")

    log.append(f"split-tunnel: {peer_count} клиент(ов) через WARP")
    return True, "\n".join(log)


def dns_status() -> str:
    """Состояние dnscrypt-proxy напрямую."""
    lines = []
    rc, out, _ = run(["systemctl", "is-active", "dnscrypt-proxy.socket"])
    active_socket = out.strip() == "active"
    rc2, out2, _ = run(["systemctl", "is-active", "dnscrypt-proxy.service"])
    active_svc = out2.strip() == "active"
    if not (active_socket or active_svc):
        rc3, out3, _ = run(["systemctl", "is-active", "dnscrypt-proxy"])
        active_svc = out3.strip() == "active"
    if active_socket or active_svc:
        lines.append("dnscrypt-proxy: 🟢 активен")
    else:
        lines.append("dnscrypt-proxy: 🔴 не активен / не установлен")
    # текущий upstream-резолвер + понятное имя, если совпадает с пресетом
    up = get_dns_upstream()
    if up:
        nice = up
        for _key, (label, servers, _nf) in DNS_UPSTREAMS.items():
            if servers == up:
                nice = f"{label}  ({up})"
                break
        lines.append(f"Резолверы: {nice}")
    # проверим, что резолвер отвечает
    if have("dig"):
        rc4, out4, _ = run(["dig", "+short", "+time=2", "+tries=1",
                            "@127.0.2.1", "example.com"])
        if rc4 == 0 and out4.strip():
            lines.append("Резолв через 127.0.2.1: 🟢 отвечает")
        else:
            lines.append("Резолв через 127.0.2.1: ⚠️ нет ответа")
    return "\n".join(lines)
