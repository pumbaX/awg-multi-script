#!/usr/bin/env python3
"""
test_xray_sub.py — подписка Xray: форматы, защита, обновление, откат.

Поддельный сервер подписки — функция curl в песочнице: адрес она берёт из
конфига в stdin (как настоящий `curl -K -`), отвечает файлами каталога SUBSRV
по последнему сегменту пути (тело, заголовки, код ошибки). Заглушка Xray
принимает конфиг, кроме выходов hysteria (как сборка без неё) и строки
REJECTME. Перезапуск туннеля — заглушка с журналом; файл restartfail в SUBSRV —
перезапуск не удался один раз.

Запуск:  python3 tests/test_xray_sub.py [путь/к/awg2.sh]
"""
import base64
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sandbox import *  # noqa: E402,F401,F403

SUBSRV = os.path.join(TMP, "subsrv")
os.makedirs(SUBSRV)
ENV["SUBSRV"] = SUBSRV
XDIR = os.path.join(ROOT, "etc/xray")
XCONF = os.path.join(XDIR, "config.json")
SUBCONF = os.path.join(XDIR, "sub.conf")
SUBLIST = os.path.join(XDIR, "sub.list")
PEERS = os.path.join(ROOT, "xray.peers")
STATEF = os.path.join(XDIR, "state")
UNITS = os.path.join(ROOT, "units")

XSTUB = os.path.join(TMP, "xray-stub")
with open(XSTUB, "w") as f:
    f.write(r"""#!/usr/bin/env bash
[[ "$1" == version ]] && { echo "Xray 26.3.27 (stub)"; exit 0; }
f=""; while (( $# )); do [[ "$1" == -c ]] && { f="$2"; shift; }; shift; done
grep -q REJECTME "$f" && { echo "failed: REJECTME"; exit 23; }
grep -q '"protocol": "hysteria"' "$f" && { echo "infra/conf: unknown config id: hysteria"; exit 23; }
echo "Configuration OK."
""")
os.chmod(XSTUB, 0o755)

EXTRA = f'''
XRAY_BIN="{XSTUB}"
mkdir -p "$XRAY_DIR"; [[ -f "$XRAY_CONF" ]] || py xray-default "$XRAY_CONF"
curl() {{
  local hdr="" proto="" url line f
  echo "curl $*" >> "$CALLS"
  while (( $# )); do case "$1" in -D) hdr="$2"; shift ;; --proto) proto="$2"; shift ;; esac; shift; done
  IFS= read -r line; url="${{line#url = \\"}}"; url="${{url%\\"}}"
  echo "$url" >> "$SUBSRV/requested"
  if [[ "$url" == http://* && "$proto" != *http,* && "$proto" != *,http ]]; then
    echo 'curl: (1) Protocol "http" not supported or disabled in libcurl' >&2; return 1
  fi
  f="$SUBSRV/${{url##*/}}"; f="${{f%%\\?*}}"
  if [[ -f "$f.rc" ]]; then cat "$f.err" >&2 2>/dev/null; return "$(cat "$f.rc")"; fi
  if [[ -f "$f.headers" ]]; then cat "$f.headers" > "$hdr"; else printf 'HTTP/1.1 200 OK\\r\\n\\r\\n' > "$hdr"; fi
  cat "$f.body"
}}
xray_restart() {{
  echo "xray_restart" >> "$CALLS"
  [[ -f "$SUBSRV/restartfail" ]] && {{ rm -f "$SUBSRV/restartfail"; return 1; }}
  return 0
}}
xray_up() {{ echo "xray_up" >> "$CALLS"; return 0; }}
xray_is_up() {{ [[ -f "$XRAY_STATE" ]]; }}
peers_sync() {{ :; }}
'''
WRAP = os.path.join(TMP, "awg2-api-sub")
with open(WRAP, "w") as f:
    f.write("#!/usr/bin/env bash\n" + PRELUDE + EXTRA + '[[ "${1:-}" == api ]] && shift\napi_main "$@"\n')
os.chmod(WRAP, 0o755)
with open(os.path.join(BIN, "systemd-run"), "w") as f:
    f.write("#!/usr/bin/env bash\nexit 1\n")
os.chmod(os.path.join(BIN, "systemd-run"), 0o755)
os.makedirs(os.path.join(ROOT, "etc/amnezia/amneziawg"), exist_ok=True)
with open(os.path.join(ROOT, "etc/amnezia/amneziawg/awg0.conf"), "w") as f:
    f.write(OLD20)


def api(*args, stdin=None):
    r = subprocess.run([WRAP, *args], input=stdin if stdin is not None else "", capture_output=True, text=True,
                       env=ENV, timeout=120)
    try:
        res = json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        res = {"raw": r.stdout + r.stderr}
    res["_rc"] = r.returncode
    return res


def sh(code, stdin=None):
    return bash(EXTRA + code, stdin)


def serve(name, body, headers=None, rc=None, err=""):
    base = os.path.join(SUBSRV, name)
    for ext in (".body", ".headers", ".rc", ".err"):
        if os.path.exists(base + ext):
            os.remove(base + ext)
    if rc is not None:
        open(base + ".rc", "w").write(str(rc))
        open(base + ".err", "w").write(err)
        return
    open(base + ".body", "wb").write(body if isinstance(body, bytes) else body.encode())
    if headers:
        open(base + ".headers", "w").write(headers)


def conf():
    return json.load(open(XCONF))


def tags():
    return [o["tag"] for o in conf()["outbounds"] if o.get("protocol") not in ("freedom", "blackhole", "dns")]


def parse(body):
    p = os.path.join(TMP, "body")
    open(p, "wb").write(body if isinstance(body, bytes) else body.encode())
    rc, out, err = sh(f'py xray-sub-parse "{p}" "{TMP}/parsed.json"; echo "rc=$?"')
    data = json.load(open(f"{TMP}/parsed.json")) if "rc=0" in out else {}
    return data, (out + err).strip()


def b64(text, urlsafe=False):
    raw = text.encode()
    return (base64.urlsafe_b64encode(raw).decode().rstrip("=") if urlsafe else base64.b64encode(raw).decode())


UUID = "0378c8eb-6544-478e-837d-c3599ef8e73d"
L_VLESS = (f"vless://{UUID}@nl1.example.net:443?encryption=none&flow=xtls-rprx-vision&security=reality"
           "&sni=www.microsoft.com&fp=chrome&pbk=PBK&sid=ab&type=tcp#%F0%9F%87%B3%F0%9F%87%B1%20%D0%9D%D0%B8%D0%B4%D0%B5%D1%80%D0%BB%D0%B0%D0%BD%D0%B4%D1%8B")
L_VMESS = "vmess://" + base64.b64encode(json.dumps({"v": "2", "ps": "DE vmess", "add": "de1.example.net", "port": "8443",
                                                     "id": UUID, "aid": "0", "net": "ws", "path": "/ws", "tls": "tls",
                                                     "sni": "de1.example.net"}).encode()).decode()
L_TROJAN = "trojan://secret@fi1.example.net:443?security=tls&sni=fi1.example.net&type=tcp#FI%20trojan"
L_SS = "ss://" + base64.urlsafe_b64encode(b"chacha20-ietf-poly1305:pass").decode().rstrip("=") + "@se1.example.net:8388#SE%20ss"
L_HY2 = "hysteria2://pw@hy.example.net:443?sni=hy.example.net#HY2"
FIVE = "\n".join([L_VLESS, L_VMESS, L_TROJAN, L_SS, L_HY2])

print("── Подписка Xray: форматы ──")
d, out = parse(b64(FIVE))
names = [i["name"] for i in d.get("items", [])]
chk("base64 (v2rayN, 3x-ui): пять серверов, имена из ссылок (эмодзи, кириллица), теги sub_хост_порт",
    d.get("format") == "base64" and len(d.get("items", [])) == 5 and names[0] == "🇳🇱 Нидерланды" and "DE vmess" in names
    and [i["tag"] for i in d["items"]][:2] == ["sub_nl1_example_net_443", "sub_de1_example_net_8443"], [out, names])
d2, out = parse(b64(FIVE.replace("\n", "\r\n"), urlsafe=True))
chk("base64 url-safe без «=» и с CRLF — то же самое", d2.get("items") == d.get("items"), out)
d3, out = parse(FIVE + "\n")
chk("ссылки открытым текстом", d3.get("format") == "links" and d3.get("items") == d.get("items"), out)
wrapped = "\n".join(b64(FIVE)[i:i + 76] for i in range(0, len(b64(FIVE)), 76))
d4, out = parse(wrapped)
chk("base64 с переносами строк (по 76 знаков)", d4.get("items") == d.get("items"), out)

J = [{"remarks": "🇩🇪 Германия", "outbounds": [
      {"tag": "proxy", "protocol": "vless", "sendThrough": "10.0.0.5",
       "settings": {"vnext": [{"address": "de2.example.net", "port": 443, "users": [{"id": UUID, "encryption": "none"}]}]},
       "streamSettings": {"network": "xhttp", "security": "reality",
                          "realitySettings": {"serverName": "x.com", "publicKey": "K", "fingerprint": "chrome"},
                          "xhttpSettings": {"path": "/x", "extra": {"downloadSettings": {"address": "dl.example.net",
                                                                                       "sockopt": {"mark": 201}}}},
                          "sockopt": {"dialerProxy": "fragment", "mark": 100, "interface": "eth0"}}},
      {"tag": "fragment", "protocol": "freedom", "settings": {"fragment": {"packets": "tlshello"}}},
      {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}]},
     {"remarks": "🇫🇮 Финляндия", "outbounds": [
      {"tag": "proxy", "protocol": "trojan",
       "settings": {"servers": [{"address": "fi2.example.net", "port": 443, "password": "p"}]}}]}]
d, out = parse(json.dumps(J))
it = d.get("items", [])
s0 = json.dumps(it[0]["ob"]) if it else ""
chk("JSON-конфиги Xray (Remnawave, Marzban): выходы с именами remarks, служебные (fragment, direct, block) — нет",
    d.get("format") == "json" and [i["name"] for i in it] == ["🇩🇪 Германия", "🇫🇮 Финляндия"]
    and [i["ob"]["protocol"] for i in it] == ["vless", "trojan"], [out, [i.get("name") for i in it]])
chk("из чужого выхода убраны sockopt (метка, интерфейс), dialerProxy и sendThrough — и в xhttp extra",
    it and "sockopt" not in s0 and "dialerProxy" not in s0 and "sendThrough" not in s0 and '"mark"' not in s0
    and it[0]["ob"]["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["address"] == "dl.example.net", s0)
for label, body, want in (
        ("sing-box", json.dumps({"outbounds": [{"type": "vless", "server": "a.example.net"}]}), "sing-box"),
        ("Clash", "proxies:\n  - name: a\n    type: vless\n", "Clash"),
        ("веб-страница", "<!DOCTYPE html><html><body>Подписка</body></html>", "веб-страница"),
        ("пустой ответ", "  \n", "пустая"),
        ("мусор", "это не подписка", "не разобран"),
        ("сломанный JSON", "[{\"outbounds\": [", "сломанный JSON"),
        ("не UTF-8", b"\xff\xfe\x00garbage", "не текст")):
    d, out = parse(body)
    chk(f"{label} — отказ с понятной причиной", not d and want in out and "Traceback" not in out, out)

LOCAL = ["vless://%s@%s:443?security=none&type=tcp#L%d" % (UUID, h, i) for i, h in enumerate(
    ["127.0.0.1", "10.1.2.3", "192.168.1.1", "localhost", "[::1]", "169.254.1.1", "100.64.0.1", "0.0.0.0", "[fd00::1]",
     "172.16.5.5", "1.2.3"])]
d, out = parse("\n".join(LOCAL + [L_TROJAN, "tuic://u:p@t.example.net:443#T", "wireguard://k@w.example.net:51820",
                                  "socks://x@s.example.net:1080"]))
chk("внутренние адреса (127.0.0.1, частные, localhost, ::1, link-local, CGNAT, 0.0.0.0) и чужие схемы — пропущены",
    [i["tag"] for i in d.get("items", [])] == ["sub_fi1_example_net_443"] and d.get("skipped") == len(LOCAL) + 3,
    [out, d.get("skipped"), [i["tag"] for i in d.get("items", [])], d.get("notes")])
d, out = parse("\n".join([L_TROJAN, L_TROJAN, L_TROJAN.replace("secret", "other")]))
chk("повтор сервера — один раз; тот же адрес с другим ключом — свой тег с номером",
    [i["tag"] for i in d.get("items", [])] == ["sub_fi1_example_net_443", "sub_fi1_example_net_443_2"], out)
many = "\n".join("trojan://p@s%d.example.net:443#S%d" % (i, i) for i in range(130))
d, out = parse(many)
chk("больше 100 серверов — берутся первые 100, с пометкой", len(d.get("items", [])) == 100
    and any("100" in n for n in d.get("notes", [])), [len(d.get("items", [])), d.get("notes")])
d, out = parse("trojan://p@ok.example.net:443#A%07B%0AC%5Ce%5B31m\n" + L_VLESS.replace("type=tcp", "type=kcp"))
chk("управляющие символы и обратная косая в имени убраны; транспорт, которого нет, — пропуск, а не падение",
    [i["name"] for i in d.get("items", [])] == ["A B C/e[31m"] and d.get("skipped") == 1, [out, d])

print("── Заголовки подписки ──")
H = ("HTTP/1.1 302 Found\r\nLocation: /sub2\r\nsubscription-userinfo: upload=1; download=1; total=1; expire=1\r\n\r\n"
     "HTTP/2 200\r\nSubscription-Userinfo: upload=1073741824; download=2147483648.0; total=10737418240; expire=1893456000\r\n"
     "Profile-Update-Interval: 12\r\nprofile-title: base64:" + base64.b64encode("Мой VPN".encode()).decode() + "\r\n\r\n")
open(os.path.join(TMP, "h1"), "w").write(H)
rc, out, _ = sh(f'py xray-sub-meta "{TMP}/h1"')
chk("subscription-userinfo, интервал и название base64 — из последнего ответа после редиректа",
    out.split() == ["UP=1073741824", "DOWN=2147483648", "TOTAL=10737418240", "EXPIRE=1893456000", "INTERVAL=12",
                    "TITLE=Мой", "VPN"], out)
open(os.path.join(TMP, "h2"), "w").write("HTTP/1.1 200 OK\r\nprofile-update-interval: 72\r\nprofile-title: Plain\r\n\r\n")
rc, out, _ = sh(f'py xray-sub-meta "{TMP}/h2"')
chk("интервал больше суток — раз в сутки; без userinfo — нули", "INTERVAL=24" in out and "TOTAL=0" in out
    and "TITLE=Plain" in out, out)

print("── Задать подписку ──")
URL = "https://sub.example.org/sub/SECRETTOKEN42?flag=1"
serve("SECRETTOKEN42", b64(FIVE), H)
reset_calls()
r = api("xray", "sub", "set", stdin=URL + "\n")
sc = open(SUBCONF).read() if os.path.exists(SUBCONF) else ""
chk("xray sub set (адрес — stdin): серверы добавлены (кроме hysteria, которую этот Xray не знает)",
    r.get("ok") and tags() == ["sub_nl1_example_net_443", "sub_de1_example_net_8443", "sub_fi1_example_net_443",
                               "sub_se1_example_net_8388"] and "HY2" in r.get("log", ""), [r, tags()])
logs = "".join(open(p, errors="replace").read() for p in [os.path.join(ROOT, "awg.log")] if os.path.exists(p))
chk("адрес подписки — только в sub.conf (600): ни в аргументах curl, ни в журналах и ответе API",
    "URL=" + URL in sc and oct(os.stat(SUBCONF).st_mode & 0o777) == "0o600" and "SECRETTOKEN42" not in calls()
    and "SECRETTOKEN42" not in logs and "SECRETTOKEN42" not in json.dumps(r), [calls()[-300:], r.get("log")])
chk("curl: только https, редиректы — только на https, не больше 3, свой User-Agent клиента",
    "--proto =https --proto-redir =https" in calls() and "--max-redirs 3" in calls() and "-A v2rayN/" in calls(),
    calls()[-400:])
st = api("xray", "sub")
d = st.get("data") or {}
chk("api xray sub: сайт без пути и ключа, серверов 4, пропущено 1, название, трафик, срок, интервал 12 ч",
    d.get("set") and d.get("site") == "sub.example.org" and d.get("count") == 4 and d.get("skipped") == 1
    and d.get("title") == "Мой VPN" and d.get("total") == 10737418240 and d.get("up") == 1073741824
    and d.get("expire") == 1893456000 and d.get("every") == 12 and d.get("error") == "" and d.get("updated", 0) > 0
    and "SECRETTOKEN42" not in json.dumps(st), d)
chk("таймер подписки: служба через API с ожиданием замка, раз в час", os.path.exists(os.path.join(UNITS, "awg-xray-sub.timer"))
    and "api xray sub update auto" in open(os.path.join(UNITS, "awg-xray-sub.service")).read()
    and "API_LOCK_WAIT=900" in open(os.path.join(UNITS, "awg-xray-sub.service")).read()
    and "systemctl enable --now awg-xray-sub.timer" in calls(), sorted(os.listdir(UNITS)))
rc, out, _ = sh("_api_readonly xray sub && echo RO1; _api_readonly xray sub status && echo RO2; "
                "_api_readonly xray sub set || echo RW1; _api_readonly xray sub update || echo RW2; "
                "_api_readonly xray sub off || echo RW3")
chk("статус — без очереди API; задать, обновить, убрать — через очередь", all(k in out for k in ("RO1", "RO2", "RW1", "RW2", "RW3")), out)
rc, out, _ = sh('py xray-outs "$XRAY_CONF" "$XRAY_SUB_LIST" | cut -f1,7')
chk("выходы для бота и панели — с именами из подписки", "sub_nl1_example_net_443\t🇳🇱 Нидерланды" in out
    and "sub_fi1_example_net_443\tFI trojan" in out, out)
main = sh('py xray-main-get "$XRAY_CONF"')[1].strip()
chk("выходов не было — по умолчанию первый сервер подписки", main == "sub_nl1_example_net_443", main)

print("── Обновление ──")
reset_calls()
r = api("xray", "sub", "update")
chk("та же подписка — «без изменений», туннель не перезапускается", r.get("ok") and "без изменений" in r.get("log", "")
    and "xray_restart" not in calls(), r)
r = api("xray", "add", "trojan://mine@my.example.net:443?security=tls&sni=my.example.net&type=tcp#mine")
api("xray", "main", "proxy_my_example_net")
api("xray", "balancer", "leastPing")
c = conf()
sel = c["routing"]["balancers"][0]["selector"]
chk("свой выход ссылкой рядом с подпиской; балансировщик — по всем", "proxy_my_example_net" in sel
    and "sub_nl1_example_net_443" in sel and c["observatory"]["subjectSelector"] == sel, sel)
api("xray", "balancer", "off")
api("xray", "main", "proxy_my_example_net")
with open(PEERS, "w") as f:
    f.write("10.23.45.2|sub_de1_example_net_8443\n10.23.45.3|sub_nl1_example_net_443\n")
FOUR = "\n".join([L_VLESS, L_TROJAN, L_SS, "trojan://n@new.example.net:443#NEW"])
serve("SECRETTOKEN42", b64(FOUR), H)
open(STATEF, "w").write("active\n")
reset_calls()
r = api("xray", "sub", "update")
peers = open(PEERS).read()
chk("сервер ушёл из подписки, новый пришёл: выходы заменены, свой выход и выход по умолчанию не тронуты",
    r.get("ok") and tags() == ["proxy_my_example_net", "sub_nl1_example_net_443", "sub_fi1_example_net_443",
                               "sub_se1_example_net_8388", "sub_new_example_net_443"]
    and sh('py xray-main-get "$XRAY_CONF"')[1].strip() == "proxy_my_example_net", [r, tags()])
chk("клиент ушедшего сервера — на выход по умолчанию, клиент оставшегося — на своём",
    "10.23.45.2\n" in peers and "10.23.45.3|sub_nl1_example_net_443" in peers and "Клиенты ушедших серверов (1)" in r.get("log", ""),
    [peers, r.get("log")])
chk("серверы поменялись, туннель включён — перезапуск", calls().count("xray_restart") == 1, calls())
before = json.dumps(conf(), sort_keys=True)
list_before = open(SUBLIST).read()
peers_before = open(PEERS).read()
serve("SECRETTOKEN42", b64(L_TROJAN + "\ntrojan://z@zz.example.net:443#Z"), H)
open(os.path.join(SUBSRV, "restartfail"), "w").close()
reset_calls()
r = api("xray", "sub", "update")
chk("туннель с новыми серверами не поднялся — откат к прежним выходам, списку и клиентам; туннель — на прежних",
    not r.get("ok") and json.dumps(conf(), sort_keys=True) == before and open(SUBLIST).read() == list_before
    and open(PEERS).read() == peers_before and "xray_up" in calls()
    and "оставлены прежние" in (api("xray", "sub")["data"]["error"]), [r.get("log"), calls()])
os.remove(STATEF)
for label, kw, want in (("404", {"rc": 22, "err": "curl: (22) The requested URL returned error: 404"}, "ошибкой 404"),
                        ("таймаут", {"rc": 28, "err": "curl: (28) Operation timed out"}, "не ответил за 60 с"),
                        ("DNS", {"rc": 6, "err": "curl: (6) Could not resolve host: sub.example.org"}, "не найден"),
                        ("пусто", {"body": "", "headers": H}, "пустая"),
                        ("HTML", {"body": "<html>login</html>"}, "веб-страница")):
    if "rc" in kw:
        serve("SECRETTOKEN42", None, rc=kw["rc"], err=kw["err"])
    else:
        serve("SECRETTOKEN42", kw["body"], kw.get("headers"))
    before = json.dumps(conf(), sort_keys=True)
    r = api("xray", "sub", "update")
    d = api("xray", "sub")["data"]
    chk(f"подписка не скачалась ({label}) — прежние серверы остаются, причина в статусе",
        not r.get("ok") and json.dumps(conf(), sort_keys=True) == before and want in d["error"]
        and "SECRETTOKEN42" not in d["error"], [r.get("log"), d["error"]])
serve("SECRETTOKEN42", "trojan://p@big.example.net:443#" + "x" * 3000)
r = sh('XRAY_SUB_MAX=1000; xray_sub_update; echo "rc=$?"')[1]
chk("ответ больше предела — отказ, не читается целиком", "rc=1" in r and "больше 2 МБ" in r, r)
serve("SECRETTOKEN42", b64(FOUR), H)

print("── Таймер: срок ──")
reset_calls()
r = api("xray", "sub", "update", "auto")
chk("таймер после неудачи час назад не прошёл — не качает", r.get("ok") and "curl" not in calls(), r)
rc, out, _ = sh('_xsub_set "CHECKED=$(( $(date +%s) - 4000 ))" "UPDATED=$(( $(date +%s) - 3 * 3600 ))" "INTERVAL=12"; '
                'xray_sub_update auto; echo "rc=$?"')
chk("до срока (12 ч из заголовка) — не качает", "rc=0" in out and "curl" not in calls(), out)
reset_calls()
rc, out, _ = sh('_xsub_set "CHECKED=$(( $(date +%s) - 4000 ))" "UPDATED=$(( $(date +%s) - 13 * 3600 ))"; '
                'xray_sub_update auto; echo "rc=$?"')
chk("срок подошёл — качает и обновляет", "rc=0" in out and "curl" in calls() and "Подписка: серверов 4" in out, out)
rc, out, _ = sh("_xsub_set 'UPDATED=a[$(touch $SUBSRV/pwned)]' 'CHECKED=x' 'INTERVAL=99'; "
                '_xsub_due && echo DUE; xray_sub_every; _xsub_num UPDATED')
chk("sub.conf из чужого бэкапа: в арифметику только цифры — код не выполняется",
    not os.path.exists(os.path.join(SUBSRV, "pwned")) and "DUE" in out and out.split()[-2:] == ["6", "0"], out)

print("── Адрес ──")
for bad, want in (("https://a.example.org/x y", "без пробелов"), ('https://a.example.org/"x', "без пробелов"),
                  ("ftp://a.example.org/sub", "https://"), ("https:///sub", "нет сайта"), ("https://:443/x", "нет сайта")):
    r = api("xray", "sub", "set", stdin=bad + "\n")
    chk(f"адрес «{bad}» — отказ", not r.get("ok") and want in r.get("log", ""), r.get("log"))
r = api("xray", "sub", "set", stdin="http://plain.example.org/sub/HTTPTOKEN\n")
chk("http без подтверждения — отказ с кодом 3 (бот и панель спросят)", r.get("rc") == 3 and "http" in r.get("log", ""), r)
serve("HTTPTOKEN", b64(L_TROJAN))
reset_calls()
r = api("xray", "sub", "set", "insecure", stdin="http://plain.example.org/sub/HTTPTOKEN\n")
chk("http с подтверждением — работает, http разрешён и для редиректов", r.get("ok") and tags() == ["proxy_my_example_net", "sub_fi1_example_net_443"]
    and "--proto =https,http --proto-redir =https,http" in calls() and api("xray", "sub")["data"]["insecure"], [r, tags()])
r = api("xray", "sub", "set", stdin=URL + "\n")
chk("смена адреса — серверы новой подписки вместо прежних", r.get("ok") and len(tags()) == 5
    and not api("xray", "sub")["data"]["insecure"], tags())
r = api("xray", "sub", "set", stdin="https://other.example.org/sub/GONE\n")
chk("новый адрес не скачался — прежняя подписка как была", not r.get("ok") and "URL=" + URL in open(SUBCONF).read()
    and len(tags()) == 5, r.get("log"))

print("── Xray не принимает ──")
serve("SECRETTOKEN42", b64(L_TROJAN + "\ntrojan://p@rejectme.example.net:443?sni=REJECTME#BAD"), H)
r = api("xray", "sub", "update")
chk("сервер, который этот Xray не принимает, — пропущен с именем, остальные применены",
    r.get("ok") and "sub_fi1_example_net_443" in tags() and not any("rejectme" in t for t in tags())
    and "BAD" in r.get("log", ""), [r.get("log"), tags()])
serve("SECRETTOKEN42", b64(L_HY2), H)
before = json.dumps(conf(), sort_keys=True)
r = api("xray", "sub", "update")
chk("ни один сервер не принят — ничего не меняется", not r.get("ok") and json.dumps(conf(), sort_keys=True) == before
    and "Ни один сервер" in r.get("log", ""), r.get("log"))

print("── Сторож, удаление ──")
reset_calls()
rc, out, _ = sh('unit_enabled() { return 1; }; xray_sub_watchdog')
chk("таймера нет (восстановили бэкап) — сторож ставит его", "systemctl enable --now awg-xray-sub.timer" in calls(), calls())
reset_calls()
os.utime(os.path.join(XDIR, ".sub-heal"), (time.time() - 4 * 3600,) * 2)
sh("xray_sub_watchdog")
chk("таймер молчит больше трёх часов — перезапуск", "systemctl" in calls() and "awg-xray-sub.timer" in calls(), calls())
serve("SECRETTOKEN42", b64(FOUR), H)
api("xray", "sub", "update")
rc, out, _ = sh('xray_del_tag sub_fi1_example_net_443')
chk("удалить сервер подписки можно — с пометкой, что он вернётся", rc == 0 and "вернётся" in out, out)
api("xray", "sub", "update")
api("xray", "del", "proxy_my_example_net")
open(STATEF, "w").write("active\n")
r = api("xray", "sub", "off")
chk("убрать подписку, когда туннель держится только на ней, — отказ", not r.get("ok") and os.path.exists(SUBCONF)
    and "только на серверах подписки" in r.get("log", ""), r.get("log"))
os.remove(STATEF)
api("xray", "add", "trojan://mine@my.example.net:443?security=tls&sni=my.example.net&type=tcp#mine")
with open(PEERS, "w") as f:
    f.write("10.23.45.2|sub_nl1_example_net_443\n10.23.45.3|sub_fi1_example_net_443\n10.23.45.4|proxy_my_example_net\n")
r = api("xray", "sub", "off")
chk("подписка убрана: её серверы, адрес и список — нет; клиенты её серверов (и удалённого руками) — на выход по "
    "умолчанию; свой выход и его клиент остались",
    r.get("ok") and tags() == ["proxy_my_example_net"] and not os.path.exists(SUBCONF) and not os.path.exists(SUBLIST)
    and open(PEERS).read() == "10.23.45.2\n10.23.45.3\n10.23.45.4|proxy_my_example_net\n"
    and "её серверов: 4" in r.get("log", "") and api("xray", "sub")["data"]["set"] is False, [r.get("log"), tags(), open(PEERS).read()])
reset_calls()
r = api("xray", "sub", "off")
chk("убрать ещё раз — «подписки нет», ничего не трогается", r.get("ok") and "Подписки нет" in r.get("log", ""), r.get("log"))
r = api("xray", "status")
chk("xray status: поле sub и имена у выходов", r.get("data", {}).get("sub") is False
    and all("name" in o for o in r["data"]["outs"]), r.get("data", {}).get("outs"))

summary()
