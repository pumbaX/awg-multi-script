#!/usr/bin/env python3
"""Эмулятор ip rule / ip route для тестов маршрутизации туннелей: правила и
таблицы — в файлах каталога $RT_DIR, route get — по приоритетам правил, как
ядро. Остальное — в настоящую заглушку песочницы (следующий ip в PATH)."""
import ipaddress
import json
import os
import sys

D = os.environ["RT_DIR"]
os.makedirs(D, exist_ok=True)
RF = os.path.join(D, "rules.json")
a = sys.argv[1:]
if a[:1] == ["-4"]:
    a = a[1:]


def load(p, d):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return d


def save(p, v):
    json.dump(v, open(p, "w"))


def kv(args):
    out, i = {}, 0
    while i < len(args):
        k = args[i]
        if k in ("from", "to", "lookup", "table", "priority", "pref", "fwmark", "dev", "metric", "src", "via", "iif", "mark"):
            out[k] = args[i + 1] if i + 1 < len(args) else ""
            i += 2
        else:
            out.setdefault("_", []).append(k)
            i += 1
    return out


def tfile(t):
    return os.path.join(D, "table.%s.json" % t)


def passthrough():
    path = os.environ["PATH"].split(":")
    me = os.path.dirname(os.path.abspath(sys.argv[0]))
    path = [p for p in path if os.path.abspath(p) != me]
    os.environ["PATH"] = ":".join(path)
    os.execvp("ip", ["ip"] + sys.argv[1:])


if a[:2] == ["rule", "add"]:
    r = kv(a[2:])
    rules = load(RF, [])
    rules.append({"prio": int(r.get("priority") or r.get("pref") or 32765), "from": r.get("from", "all"),
                  "fwmark": r.get("fwmark", ""), "lookup": r.get("lookup") or r.get("table")})
    save(RF, rules)
elif a[:2] == ["rule", "del"]:
    r = kv(a[2:])
    rules = load(RF, [])
    for i, x in enumerate(rules):
        if ((not r.get("lookup") or x["lookup"] == r["lookup"]) and (not r.get("from") or x["from"] == r["from"])
                and (not r.get("fwmark") or x["fwmark"] == r["fwmark"])
                and (not r.get("priority") or x["prio"] == int(r["priority"]))):
            del rules[i]
            save(RF, rules)
            sys.exit(0)
    sys.stderr.write("RTNETLINK answers: No such file or directory\n")
    sys.exit(2)
elif a[:2] in (["rule", "show"], ["rule", "list"]) or a == ["rule"]:
    for x in sorted(load(RF, []), key=lambda x: x["prio"]):
        print("%d:\tfrom %s%s lookup %s" % (x["prio"], x["from"], " fwmark " + x["fwmark"] if x["fwmark"] else "", x["lookup"]))
elif a[:2] == ["route", "flush"] and "cache" in a:
    pass
elif a[:1] == ["route"] and len(a) > 1 and a[1] in ("replace", "add", "del", "flush", "show") and "table" in a:
    r = kv(a[2:])
    t = r["table"]
    routes = load(tfile(t), [])
    kind = "unreachable" if "unreachable" in r.get("_", []) else "dev"
    metric = int(r.get("metric") or 0)
    if a[1] in ("replace", "add"):
        routes = [x for x in routes if not (x["metric"] == metric)]
        routes.append({"kind": kind, "dev": r.get("dev", ""), "metric": metric, "nexthop": "nexthop" in r.get("_", [])})
        save(tfile(t), routes)
    elif a[1] == "del":
        n = [x for x in routes if not (x["kind"] == kind and x["metric"] == metric)]
        if len(n) == len(routes):
            sys.exit(2)
        save(tfile(t), n)
    elif a[1] == "flush":
        save(tfile(t), [])
    else:
        for x in sorted(routes, key=lambda x: x["metric"]):
            if x["kind"] == "unreachable":
                print("unreachable default metric %d" % x["metric"])
            else:
                print("default dev %s%s" % (x["dev"], " metric %d" % x["metric"] if x["metric"] else ""))
elif a[:2] == ["route", "get"]:
    r = kv(a[2:])
    dst, src, mark = a[2], r.get("from", ""), r.get("mark", "")
    links = open(os.environ["LINKS"]).read().split() if os.path.exists(os.environ.get("LINKS", "")) else []
    if r.get("iif") and r["iif"] not in links:
        sys.stderr.write('Cannot find device "%s"\n' % r["iif"])
        sys.exit(1)
    for x in sorted(load(RF, []), key=lambda x: x["prio"]) + [{"prio": 32766, "from": "all", "fwmark": "", "lookup": "main"}]:
        if x["from"] != "all" and (not src or ipaddress.ip_address(src) not in ipaddress.ip_network(x["from"], strict=False)):
            continue
        if x["fwmark"]:
            val = x["fwmark"].split("/")[0]
            if mark.lower() != val.lower():
                continue
        if x["lookup"] == "main":
            print("%s from %s via 192.0.2.1 dev eth0 iif %s" % (dst, src, r.get("iif", "")))
            sys.exit(0)
        routes = sorted(load(tfile(x["lookup"]), []), key=lambda y: y["metric"])
        live = [y for y in routes if y["kind"] == "dev" and y["dev"] in links]
        if live:
            print("%s from %s dev %s table %s iif %s" % (dst, src, live[0]["dev"], x["lookup"], r.get("iif", "")))
            sys.exit(0)
        if any(y["kind"] == "unreachable" for y in routes):
            sys.stderr.write("RTNETLINK answers: No route to host\n")
            sys.exit(2)
    print("%s from %s via 192.0.2.1 dev eth0" % (dst, src))
else:
    passthrough()
