"use strict";
// AWG Toolza — Mini App. Всё идёт через API бота (webapp.py, panel.py) с
// подписью Telegram в каждом запросе: страница ничего не хранит, а без
// Telegram сервер ей ничего не отдаст.
// Та же страница — веб-панель (служба awg-web): вход по логину и паролю,
// сессия в cookie, адрес с секретным путём; сервер кладёт window.AWG_WEB.

// Старый движок встроенного браузера — Edge 18 (EdgeHTML) в Telegram Desktop
// для Windows без WebView2: того, чего в нём нет, а панели нужно, — здесь.
// Синтаксис панели — тоже по его силам: без новинок ES2019+ (оператор
// нулевого слияния, catch без переменной, разворот объекта в литерале);
// цвета hsl() — через запятые: hsl(156 80% 58%) он не понимает (пустые кружки).
if (!Array.prototype.flat) {
  Object.defineProperty(Array.prototype, "flat", { configurable: true, writable: true, value: function flat(depth = 1) {
    return depth > 0 ? this.reduce((a, x) => a.concat(Array.isArray(x) ? x.flat(depth - 1) : x), []) : this.slice();
  } });
}
[Element, Document, DocumentFragment].forEach((C) => {
  if (!C.prototype.replaceChildren) C.prototype.replaceChildren = function replaceChildren(...nodes) {
    while (this.lastChild) this.removeChild(this.lastChild);
    this.append(...nodes);
  };
});
if (!Object.fromEntries) Object.fromEntries = (pairs) => { const o = {}; for (const [k, v] of pairs) o[k] = v; return o; };
if (!String.prototype.trimStart) String.prototype.trimStart = function trimStart() { return this.replace(/^\s+/, ""); };
if (window.Blob && !Blob.prototype.text) Blob.prototype.text = function text() { return new Response(this).text(); };
// gap у flex там тоже не работает (у grid — работает): иконки слипались с
// подписями. Зазоры flex-контейнеров — отступами у их детей.
const FLEX_GAP = (() => {
  const d = document.createElement("div");
  d.style.cssText = "display:flex;flex-direction:column;row-gap:1px;position:absolute;visibility:hidden";
  d.append(document.createElement("div"), document.createElement("div"));
  document.body.append(d);
  const ok = d.scrollHeight === 1;
  d.remove();
  return ok && !window.AWG_FORCE_NOGAP;
})();
function gapFix(el) {
  if (!el || el.nodeType !== 1) return;
  const cs = getComputedStyle(el);
  if (!/flex/.test(cs.display)) return;
  const cg = parseFloat(cs.columnGap || cs.gridColumnGap) || 0, rg = parseFloat(cs.rowGap || cs.gridRowGap) || 0;
  if (!cg && !rg) return;
  // Ряд с переносом — отступ справа у всех, кроме последнего: слева он сдвигал
  // перенесённый на новую строку элемент от края
  const col = /column/.test(cs.flexDirection), wrap = !col && cs.flexWrap !== "nowrap";
  const side = col ? "marginTop" : wrap ? "marginRight" : "marginLeft", g = col ? rg : cg;
  const kids = [...el.children].filter((k) => { const ks = getComputedStyle(k);
    return ks.display !== "none" && ks.position !== "absolute" && ks.position !== "fixed"; });
  kids.forEach((k, i) => {
    const ks = getComputedStyle(k), want = g && (wrap ? i < kids.length - 1 : i > 0);
    // Свой отступ (margin-left: auto и т. п.) не трогаем — только нулевой или поставленный здесь
    if (want && (k.dataset.gapm === side || ks[side] === "0px")) { k.style[side] = g + "px"; k.dataset.gapm = side; }
    else if (!want && k.dataset.gapm) { k.style[k.dataset.gapm] = ""; delete k.dataset.gapm; }
    if (wrap && rg && (k.dataset.gapb || ks.marginBottom === "0px")) { k.style.marginBottom = rg + "px"; k.dataset.gapb = "1"; }
  });
}
if (!FLEX_GAP) {
  const run = (n) => { if (n.nodeType !== 1) return; gapFix(n); n.querySelectorAll("*").forEach(gapFix); };
  new MutationObserver((ms) => ms.forEach((m) => { gapFix(m.target); m.addedNodes.forEach(run); }))
    .observe(document.body, { childList: true, subtree: true });
}

const WEB = window.AWG_WEB || null;
const tg = !WEB && window.Telegram && window.Telegram.WebApp;
const BASE = WEB ? WEB.base : "/";
const url = (p) => BASE + String(p).replace(/^\//, "");
const root = document.getElementById("app");
// Веб-панель на широком экране (ПК): таблицы, колонки, окна по центру
const DESK_MQ = window.matchMedia ? matchMedia("(min-width: 1000px)") : null;
const desk = () => !!WEB && !!DESK_MQ && DESK_MQ.matches;
const S = { me: null, version: "", channel: "", update: "", status: null, clients: null, sort: null, view: null, filter: "all", q: "",
  select: null, live: null, listShown: false, listRedraw: null };

// ── Связь с ботом ─────────────────────────────────────────
// bg — фоновый опрос (живая скорость): сессию веб-панели он не продлевает,
// иначе открытый обзор держал бы вход вместо «12 часов без действий»
// ms — сколько ждать ответа: /api/call — таймаут awg2 и ещё 15 с, удаление
// и другие записи — как у awg2 (до 180 с), остальное — минута. Не ответил —
// понятная ошибка, а не вечная «Загрузка…»
// Ждём чуть дольше сервера: по умолчанию он ждёт awg2 до 180 с, отправка в чат — до 300 с
const postWait = (path, body) => (path === "/api/call" ? ((+body.timeout || 120) + 15) * 1000
  : path === "/api/client/del" ? 615e3 : path === "/api/send" ? 315e3 : 195e3);
async function post(path, body = {}, bg = false, ms = 0) {
  const headers = WEB ? { "Content-Type": "application/json" }
    : { "Content-Type": "application/json", Authorization: "tma " + (tg ? tg.initData : "") };
  if (bg) headers["X-Awg-Bg"] = "1";
  const wait = ms || postWait(path, body);
  const ac = window.AbortController ? new AbortController() : null;
  const timer = ac ? setTimeout(() => ac.abort(), wait) : 0;
  let r, d;
  try {
    r = await fetch(url(path), {
      method: "POST",
      credentials: "same-origin",
      headers,
      body: JSON.stringify(body),
      signal: ac ? ac.signal : undefined,
    });
    d = await r.json().catch(() => ({}));
  } catch (e) {
    // «Failed to fetch» / «Load failed» — это обрыв связи, так и пишем
    throw new Error(ac && ac.signal.aborted ? `Сервер не ответил за ${Math.round(wait / 1000)} с — действие могло завершиться на сервере`
      : "Нет связи с сервером");
  } finally { clearTimeout(timer); }
  if (ac && ac.signal.aborted) throw new Error(`Сервер не ответил за ${Math.round(wait / 1000)} с — действие могло завершиться на сервере`);
  if (WEB && r.status === 401 && d.login) { showLogin(); const e = new Error("Нужен вход"); e.login = true; throw e; }
  if (!r.ok || d.ok === false) {
    const e = new Error(d.error || `HTTP ${r.status}`);
    e.log = d.log || "";
    throw e;
  }
  return d;
}
const call = async (...args) => (await post("/api/call", { args })).data;

// Файл: в Mini App — в чат с ботом, в веб-панели — скачиванием
async function download(body) {
  const r = await fetch(url("/api/download"), { method: "POST", credentials: "same-origin",
    headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) })
    .catch(() => { throw new Error("Нет связи с сервером"); });
  if (!r.ok || (r.headers.get("Content-Type") || "").startsWith("application/json")) {
    const d = await r.json().catch(() => ({}));
    if (r.status === 401 && d.login) { showLogin(); const e = new Error("Нужен вход"); e.login = true; throw e; }
    const e = new Error(d.error || `HTTP ${r.status}`);
    e.log = d.log || "";
    throw e;
  }
  const name = (/filename="([^"]+)"/.exec(r.headers.get("Content-Disposition") || "") || [])[1] || "file";
  const a = h("a", { href: URL.createObjectURL(await r.blob()), download: name });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 10000);
  return name;
}
async function deliver(body, chatNote) {
  if (WEB) { const name = await download(body); haptic(); toast("⬇️ Скачано: " + name, 3000); return; }
  await post("/api/send", body); haptic(); toast(chatNote, 3000);
}
// Подпись кнопки: в Mini App — «в чат», в веб-панели — «скачать»
const TO = (chat, file) => (WEB ? file : chat);

// ── Мелочи ────────────────────────────────────────────────
function h(tag, props, ...kids) {
  // Кнопка «📦 Установить» получает линейную иконку вместо эмодзи
  if (tag === "button" && typeof kids[0] === "string") kids[0] = withIcon(kids[0]);
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid != null && kid !== false) el.append(kid instanceof Node ? kid : String(kid));
  }
  return el;
}
const plural = (n, one, few, many) => {
  const a = Math.abs(n) % 100, b = a % 10;
  return b === 1 && a !== 11 ? one : b >= 2 && b <= 4 && (a < 12 || a > 14) ? few : many;
};
function fmtBytes(n) {
  n = Number(n || 0);
  for (const u of ["Б", "КБ", "МБ", "ГБ"]) {
    if (u === "Б" ? n < 1024 : n < 1023.95) return u === "Б" ? `${n} ${u}` : `${n.toFixed(1)} ${u}`;
    n /= 1024;
  }
  return `${n.toFixed(1)} ТБ`;
}
function fmtDur(s) {
  s = Math.max(0, Math.floor(s || 0));
  if (s < 60) return `${s}с`;
  if (s < 3600) return `${Math.floor(s / 60)}м`;
  if (s < 86400) return `${Math.floor(s / 3600)}ч ${Math.floor(s % 3600 / 60)}м`;
  return `${Math.floor(s / 86400)}д ${Math.floor(s % 86400 / 3600)}ч`;
}
const fmtTime = (ts) => new Date(ts * 1000).toLocaleString("ru-RU",
  { day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" });
function fmtExpire(ts) {
  if (!ts) return "бессрочно";
  const left = ts - Date.now() / 1000;
  return `${fmtTime(ts)} (${left > 0 ? "через " + fmtDur(left) : "истёк"})`;
}
const haptic = (t = "success") => tg && tg.HapticFeedback && tg.HapticFeedback.notificationOccurred(t);
const kv = (k, v) => h("div", { class: "kv" }, h("span", {}, k), h("span", {}, v));

// Трафик по дням (awg2 api traffic daily): столбик — приём и отдача за день.
// Касание или наведение — подпись дня над графиком; без выбора — последний день.
const SVG_NS = "http://www.w3.org/2000/svg";
function svg(tag, attrs) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  return el;
}
const fmtDay = (d) => `${d.slice(8)}.${d.slice(5, 7)}`;
// Столбцы (по дням или по клиентам): касание или наведение — подпись над
// графиком; без выбора — столбец def. items: [{label, value, detail}].
function barChart(items, { def = items.length - 1, axis = null } = {}) {
  const n = items.length, max = Math.max(1, ...items.map((x) => x.value)), W = desk() ? 900 : 300, H = 96, gap = 2;
  // Столбец в своей доле ширины, но не шире 1/8 графика — при двух-трёх клиентах не плиты
  const slot = Math.max(1, (W - gap * (n - 1)) / n), bw = Math.min(slot, W / 8);
  const box = h("div", { class: "chart", role: "img",
    "aria-label": items.map((x) => `${x.label}: ${fmtBytes(x.value)}`).join(", ") });
  const cap = h("div", { class: "cap" });
  const plot = svg("svg", { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none" });
  const bars = [];
  const show = (i, sel) => {
    const x = items[i];
    cap.textContent = `${x.label} · ${x.value ? fmtBytes(x.value) : "нет трафика"}` + (x.value && x.detail ? ` (${x.detail})` : "");
    box.classList.toggle("sel", sel);
    bars.forEach((el, j) => el && el.classList.toggle("on", sel && j === i));
  };
  items.forEach((it, i) => {
    const x = i * (slot + gap) + (slot - bw) / 2, bh = it.value ? Math.max(2, (H - 2) * it.value / max) : 0, y = H - bh;
    if (bh) {
      // Скругление 4 px — только у верхнего края, основание прямое
      const r = Math.min(4, bw / 2, bh);
      bars[i] = svg("path", { class: "bar", d: `M${x},${H}V${y + r}Q${x},${y} ${x + r},${y}H${x + bw - r}`
        + `Q${x + bw},${y} ${x + bw},${y + r}V${H}Z` });
      plot.append(bars[i]);
    }
    const hit = svg("rect", { class: "hit", x: i * (slot + gap) - gap / 2, y: 0, width: slot + gap, height: H });
    hit.addEventListener("pointerenter", () => show(i, true));
    hit.addEventListener("click", () => show(i, true));
    plot.append(hit);
  });
  plot.append(svg("line", { class: "base", x1: 0, x2: W, y1: H - 0.5, y2: H - 0.5 }));
  plot.addEventListener("pointerleave", () => show(def, false));
  if (n) show(def, false);
  box.append(cap, plot, axis || h("div", { class: "ax" }, h("span", {}), h("span", {}, `макс ${fmtBytes(max)}`), h("span", {})));
  return box;
}

const dayDetail = (d, i) => `↓ ${fmtBytes(d.rx[i])} · ↑ ${fmtBytes(d.tx[i])}`;
const dayAxis = (d, max) => h("div", { class: "ax" }, h("span", {}, d.days.length ? fmtDay(d.days[0]) : ""),
  h("span", {}, `макс ${fmtBytes(max)}`), h("span", {}, "сегодня"));

// Трафик по дням линией (awg2 api traffic daily): приём и отдача вместе.
// Касание или наведение — точка дня и подпись; без выбора — сегодня.
function lineChart(d, { H = 80 } = {}) {
  // На ПК график растянут по ширине (своя высота): линии без утолщения, точка — HTML поверх
  const days = d.days || [], n = days.length, W = desk() ? 900 : 300, P = 4;
  const tot = days.map((_, i) => (d.rx[i] || 0) + (d.tx[i] || 0));
  const max = Math.max(1, ...tot);
  const X = (i) => (n > 1 ? P + i * (W - 2 * P) / (n - 1) : W / 2), Y = (v) => H - 1 - (H - 8) * v / max;
  const box = h("div", { class: "chart line", role: "img",
    "aria-label": `Трафик за ${n} дн.: всего ${fmtBytes(tot.reduce((a, b) => a + b, 0))}` });
  const cap = h("div", { class: "cap" });
  const plot = svg("svg", { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none" });
  const pts = tot.map((v, i) => `${X(i).toFixed(1)},${Y(v).toFixed(1)}`);
  if (n) {
    plot.append(svg("path", { class: "area", d: `M${pts.join("L")}L${X(n - 1)},${H}L${X(0)},${H}Z` }),
      svg("path", { class: "ln", d: "M" + pts.join("L") }));
  }
  plot.append(svg("line", { class: "base", x1: 0, x2: W, y1: H - 0.5, y2: H - 0.5 }));
  const cross = svg("line", { class: "cross", y1: 0, y2: H }), dot = h("i", { class: "pt" });
  plot.append(cross);
  const show = (i, sel) => {
    cap.textContent = `${fmtDay(days[i])} · ${tot[i] ? fmtBytes(tot[i]) : "нет трафика"}` + (tot[i] ? ` (${dayDetail(d, i)})` : "");
    cross.setAttribute("x1", X(i)); cross.setAttribute("x2", X(i));
    dot.style.left = `${X(i) * 100 / W}%`; dot.style.top = `${Y(tot[i]) * 100 / H}%`;
    box.classList.toggle("sel", sel);
  };
  days.forEach((_, i) => {
    const w = n > 1 ? (W - 2 * P) / (n - 1) : W;
    const hit = svg("rect", { class: "hit", x: X(i) - w / 2, y: 0, width: w, height: H });
    hit.addEventListener("pointerenter", () => show(i, true));
    hit.addEventListener("click", () => show(i, true));
    plot.append(hit);
  });
  plot.addEventListener("pointerleave", () => show(n - 1, false));
  if (n) show(n - 1, false);
  box.append(cap, h("div", { class: "plotw" }, plot, n ? dot : null), dayAxis(d, max));
  return box;
}

// Мини-линия для свёрнутой карточки
function sparkline(values) {
  const n = values.length, max = Math.max(1, ...values), W = 64, H = 18;
  const pts = values.map((v, i) => `${(n > 1 ? i * W / (n - 1) : W / 2).toFixed(1)},${(H - 1 - (H - 3) * v / max).toFixed(1)}`);
  const el = svg("svg", { class: "spark", viewBox: `0 0 ${W} ${H}`, "aria-hidden": "true" });
  if (n) el.append(svg("path", { d: "M" + pts.join("L") }));
  return el;
}

// Полоска «израсходовано из лимита»
const meter = (used, limit) => {
  const pct = Math.min(100, Math.round(used * 100 / Math.max(limit, 1)));
  return h("div", { class: "meter" + (pct >= 100 ? " bad" : pct >= 90 ? " warn" : "") }, h("i", { style: `width:${pct}%` }));
};
const PERIOD = { month: "за месяц", total: "всего" };
const limitText = (c) => `${fmtBytes(c.used)} из ${fmtBytes(c.limit)} ${PERIOD[c.period] || ""}`;

// ── Вид: иконки, тема, шапка, общие детали ────────────────
function icon(name) {
  const t = document.createElement("template");
  t.innerHTML = `<svg class="i" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] || ""}</svg>`;
  return t.content.firstChild;
}
// Эмодзи в начале подписи → линейная иконка того же смысла (icons.js)
const EMOJI_ICON = {
  "🔄": "refresh-cw", "🔀": "shuffle", "🌍": "globe", "📍": "map-pin", "🧩": "cpu", "📦": "package", "🛠": "wrench",
  "♻": "rotate-ccw", "⚠": "triangle-alert", "✨": "sparkles", "🗑": "trash-2", "📜": "file-text", "▶": "play",
  "⏹": "square", "👥": "users", "🔑": "key", "📥": "download", "🔎": "search", "🔍": "search", "⚖": "scale",
  "🩺": "stethoscope", "➕": "plus", "➖": "minus", "🧹": "eraser", "💾": "save", "📤": "upload", "🤖": "bot",
  "⬆": "circle-arrow-up", "⬇": "arrow-down", "📋": "list", "🔁": "repeat", "🧱": "layers", "⏪": "undo-2",
  "✏": "pencil", "📄": "file-text", "✉": "send", "🎲": "dices", "🎭": "drama", "⏳": "hourglass", "📝": "notebook-pen",
  "🔢": "hash", "🌐": "network", "🚨": "siren", "🎯": "crosshair", "📎": "paperclip", "🔔": "bell", "🔕": "bell-off",
  "📅": "calendar-clock", "♾": "infinity", "🚪": "door-open", "☁": "cloud", "🛰": "satellite", "🧦": "waypoints",
  "🔐": "lock-keyhole", "🧪": "flask-conical", "🖥": "server", "🛡": "shield", "📁": "folder", "🗜": "file-archive",
  "◀": "arrow-left", "✅": "circle-check", "❌": "circle-x", "✖": "x", "🔃": "arrow-down-up", "📂": "folder",
  "👮": "user", "🎨": "palette", "📶": "gauge", "📊": "chart-column", "📈": "chart-column", "🕒": "clock", "🎛": "sliders-horizontal", "↩": "undo-2", "💬": "message-square-text", "📱": "smartphone", "🔗": "share-2", "🙋": "user-plus", "🧯": "eraser",
};
// \p{…} старый движок не знает (вся панель падала на этой строке) — там
// эмодзи узнаётся по суррогатной паре или блоку символов
const EMOJI_RE = (() => {
  try { return new RegExp("^(\\p{Extended_Pictographic})\\uFE0F?\\s*", "u"); } catch (_) {
    return /^([\uD83C-\uDBFF][\uDC00-\uDFFF]|[\u00A9\u00AE\u203C\u2049\u2122\u2139\u2190-\u2BFF\u3030\u303D\u3297\u3299])\uFE0F?\s*/;
  }
})();
function withIcon(label) {
  const m = EMOJI_RE.exec(label);
  const name = m && EMOJI_ICON[m[1]];
  return name ? [icon(name), label.slice(m[0].length)] : label;
}
const plainTitle = (text) => (typeof text === "string" ? text.replace(EMOJI_RE, "") : text);
// Заголовок экрана — без эмодзи, как в AWG Manager; extra — пометки справа
const title = (text, ...extra) => h("h1", {}, plainTitle(text), extra);
const pill = (text, cls = "") => h("span", { class: "pill " + cls }, text);
const tag = (text, cls = "", ic = null) => h("span", { class: "tag " + cls }, ic ? icon(ic) : null, text);
// Сводка 2×2: [число, ПОДПИСЬ, пояснение, onclick]
const statGrid = (cells) => h("div", { class: "sgrid" }, cells.filter(Boolean).map(([big, label, sub, onclick]) =>
  h("div", { class: "cell" + (onclick ? " tap" : ""), onclick },
    h("b", { class: String(big).length > 9 ? "long" : null }, big), h("div", { class: "lb" }, label),
    sub ? h("div", { class: "sb" }, sub) : null)));
// Карточка объекта: рамка и точка по состоянию (on | bad | warn), чипы, строки, действия
function ecard({ state = "", cls = "", name, right, meta, lines, note, acts, onopen, attrs = {} }) {
  return h("div", Object.assign({ class: `ecard ${state} ${cls}` }, attrs),
    h("div", { class: "head", onclick: onopen }, h("div", { class: "dot " + state }), h("div", { class: "name" }, name), right),
    meta && meta.length ? h("div", { class: "meta", onclick: onopen }, meta) : null,
    (lines || []).filter(Boolean).map((l) => h("div", { class: "line", onclick: onopen }, l)),
    note ? h("div", { class: "note" }, note) : null,
    acts && acts.length ? h("div", { class: "acts" }, acts) : null);
}
const act = (ic, label, onclick, cls) => h("button", { class: cls || null,
  onclick: (ev) => { ev.stopPropagation(); onclick(ev.currentTarget); } }, icon(ic), label);
const tabsBar = (items, cur, pick) => h("div", { class: "tabs" }, items.map(([k, label, n]) =>
  h("button", { class: k === cur ? "on" : null, onclick: () => pick(k) }, label, n != null ? h("span", { class: "n" }, n) : null)));
const segText = (items, cur, pick) => h("div", { class: "seg" }, items.map(([k, label]) =>
  h("button", { class: k === cur ? "on" : null, onclick: () => pick(k) }, label)));
const segBar = (items, cur, pick) => h("div", { class: "seg" }, items.map(([k, ic, label]) =>
  h("button", { class: k === cur ? "on" : null, "aria-label": label, title: label, onclick: () => pick(k) }, icon(ic))));
// Мелкие настройки вида — только в этом браузере
const pref = (k, def) => { try { return localStorage.getItem("awg-" + k) || def; } catch (_) { return def; } };
const setPref = (k, v) => { try { localStorage.setItem("awg-" + k, v); } catch (_) { /* приватный режим */ } };

// ── Вид: тема, акцент, фон, скругление, масштаб — панель «Тема» ──
// Хранится в этом браузере; «Авто» — как тема Telegram (в Mini App) или системы
const LOOK_DEF = { mode: "auto", hue: null, sat: 80, bgHue: null, tint: 22, rb: 16, zoom: 100, grid: false, tab: "logo" };
const ZOOM_MIN = 75, ZOOM_MAX = 130;
function loadLook() {
  let v = null;
  try { v = JSON.parse(pref("look", "") || "null"); } catch (_) { v = null; }
  // Прежний «Вид панели»: тема и размер переезжают сюда
  if (!v || typeof v !== "object") v = { mode: pref("theme", "") || "auto", zoom: Number(pref("scale", "100")) || 100 };
  const L = Object.assign({}, LOOK_DEF, v);
  L.zoom = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, Number(L.zoom) || 100));
  if (!["auto", "dark", "light"].includes(L.mode)) L.mode = "auto";
  if (!["logo", "flag"].includes(L.tab)) L.tab = "logo";
  return L;
}
let LOOK = loadLook();
const autoTheme = () => (WEB ? (window.matchMedia && matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark")
  : tg && tg.colorScheme === "light" ? "light" : "dark");
const themeNow = () => (LOOK.mode === "dark" || LOOK.mode === "light" ? LOOK.mode : autoTheme());
const BG_VARS = ["--bg", "--bg2", "--panel", "--panel2", "--hover", "--line", "--line2"];
const rgbHex = (rgb) => "#" + (rgb.match(/\d+/g) || [0, 0, 0]).slice(0, 3).map((x) => (+x).toString(16).padStart(2, "0")).join("");

// Знак Тулзы — в цвет акцента, как слово «toolza»: у каждого цвета SVG оттенок
// сдвигается от зелёного Toolza (156°) к выбранному, насыщенность — по ползунку,
// яркость остаётся (блики и тени знака на месте). Акцент по умолчанию — исходный файл.
const TZ_HUE = 156, TZ_SAT = 80;
function tzHex(hex, dh, ks) {
  const n = parseInt(hex, 16), r = (n >> 16) / 255, g = ((n >> 8) & 255) / 255, b = (n & 255) / 255;
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, d = mx - mn;
  let hh = 0, ss = 0;
  if (d) {
    ss = d / (1 - Math.abs(2 * l - 1));
    hh = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
    hh *= 60;
  }
  hh = (hh + dh + 720) % 360; ss = Math.min(1, ss * ks);
  const c = (1 - Math.abs(2 * l - 1)) * ss, x = c * (1 - Math.abs((hh / 60) % 2 - 1)), m = l - c / 2;
  const [r1, g1, b1] = hh < 60 ? [c, x, 0] : hh < 120 ? [x, c, 0] : hh < 180 ? [0, c, x] : hh < 240 ? [0, x, c] : hh < 300 ? [x, 0, c] : [c, 0, x];
  return [r1, g1, b1].map((v) => Math.round((v + m) * 255).toString(16).padStart(2, "0")).join("");
}
function tzIcon(big = false) {
  const src = big ? TZ_ICON_BIG : TZ_ICON;
  if (LOOK.hue == null || (LOOK.hue === TZ_HUE && LOOK.sat === TZ_SAT)) return src;
  const key = `${big ? "b" : "s"}${LOOK.hue}/${LOOK.sat}`, memo = tzIcon.memo || (tzIcon.memo = new Map());
  if (!memo.has(key)) {
    if (memo.size > 8) memo.clear();          // ползунок оттенка: не копить знак на каждый градус
    const dh = LOOK.hue - TZ_HUE, ks = LOOK.sat / TZ_SAT;
    try {
      const text = atob(src.slice(src.indexOf(",") + 1)).replace(/#([0-9a-f]{6})\b/gi, (_, hex) => "#" + tzHex(hex, dh, ks));
      memo.set(key, "data:image/svg+xml;charset=utf-8," + encodeURIComponent(text));
    } catch (_) { memo.set(key, src); }       // не вышло — знак исходного цвета, панель работает
  }
  return memo.get(key);
}
// Акцент сменился: знаки на экране, на схеме и во вкладке браузера — в новый цвет
function tzRefresh() {
  document.querySelectorAll("img.tz").forEach((i) => { i.src = tzIcon(i.classList.contains("big")); });
  document.querySelectorAll("image.tz").forEach((i) => i.setAttribute("href", tzIcon()));
  favRefresh();
}
// Значок вкладки браузера (веб-панель): знак Тулзы или флаг страны сервера с точкой
// состояния awg0 — много вкладок с разными серверами различаются с первого взгляда
function favRefresh() {
  const fav = document.getElementById("favicon");
  if (!fav) return;
  const st = S.status || {}, cc = String(st.country || "").replace(/[^A-Z]/g, "").slice(0, 2);
  const set = (href) => { if (fav.getAttribute("href") !== href) fav.href = href; };
  if (!WEB || LOOK.tab !== "flag" || !cc) { set(tzIcon()); return; }
  const dot = { "": "#22c55e", bad: "#ef4444", off: "#9ca3af" }[srvPulse(st)];
  const body = FLAGS[cc] ? `<svg x="0" y="5" width="32" height="22" viewBox="0 0 30 20" preserveAspectRatio="none">${flagBody(FLAGS[cc])}</svg>`
    : `<rect y="5" width="32" height="22" fill="#4b5563"/><text x="16" y="21" text-anchor="middle" font-family="sans-serif" font-weight="700"
      font-size="12" fill="#fff">${cc}</text>`;
  set("data:image/svg+xml;charset=utf-8," + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
    <defs><clipPath id="c"><rect y="5" width="32" height="22" rx="4"/></clipPath></defs><g clip-path="url(#c)">${body}</g>
    <rect x=".5" y="5.5" width="31" height="21" rx="3.5" fill="none" stroke="rgba(0,0,0,.25)"/>
    <circle cx="26" cy="25" r="5.5" fill="${dot}" stroke="#fff" stroke-width="2"/></svg>`));
}

function applyLook(save = false) {
  const el = document.documentElement, st = el.style, mode = themeNow(), dark = mode === "dark";
  el.dataset.theme = mode;
  ["--acc", "--acc-ink", "--acc-soft", ...BG_VARS].forEach((p) => st.removeProperty(p));
  if (LOOK.hue != null) {
    const hh = LOOK.hue, sat = LOOK.sat, L = dark ? 58 : 32;
    st.setProperty("--acc", `hsl(${hh}, ${sat}%, ${L}%)`);
    st.setProperty("--acc-ink", dark ? `hsl(${hh}, 60%, 9%)` : `hsl(${hh}, 80%, 97%)`);
    st.setProperty("--acc-soft", `hsla(${hh}, ${sat}%, ${L}%, .13)`);
  }
  if (LOOK.bgHue != null) {
    const Ls = dark ? [4.5, 6, 8.5, 11, 13, 16, 21] : [94, 91, 98.5, 96, 92.5, 86, 80];
    BG_VARS.forEach((p, i) => st.setProperty(p, `hsl(${LOOK.bgHue}, ${dark ? LOOK.tint : LOOK.tint * 0.8}%, ${Ls[i]}%)`));
  }
  st.setProperty("--rb", LOOK.rb + "px");
  st.setProperty("--rc", Math.round(LOOK.rb * 0.62) + "px");
  // Масштаб — всей панели: кнопки и карточки сохраняют пропорции, подписи не переносятся
  st.zoom = LOOK.zoom === 100 ? "" : String(LOOK.zoom / 100);
  document.body.classList.toggle("grid-bg", !!LOOK.grid);
  try { tzRefresh(); } catch (_) { /* знак остаётся прежнего цвета */ }
  if (save) setPref("look", JSON.stringify(LOOK));
  try {
    const bg = rgbHex(getComputedStyle(document.body).backgroundColor);
    if (tg && tg.setHeaderColor) tg.setHeaderColor(bg);
    if (tg && tg.setBackgroundColor) tg.setBackgroundColor(bg);
  } catch (_) { /* старый Telegram: цвета шапки не меняются */ }
}
applyLook();

const SWATCH = [["Toolza", 156, 80], ["Лайм", 78, 85], ["Океан", 198, 80], ["Индиго", 232, 75], ["Фиалка", 268, 70],
  ["Роза", 336, 75], ["Закат", 16, 85], ["Янтарь", 40, 92]];
// Кольцо «израсходовано из лимита»
function ringSvg(p, size = 26, w = 4) {
  const r = (size - w) / 2, len = 2 * Math.PI * r, col = p >= 100 ? "var(--red)" : p >= 85 ? "var(--amber)" : "var(--acc)";
  const s = svg("svg", { viewBox: `0 0 ${size} ${size}`, width: size, height: size, "aria-hidden": "true" });
  s.append(svg("circle", { cx: size / 2, cy: size / 2, r, fill: "none", stroke: "var(--line2)", "stroke-width": w }),
    svg("circle", { cx: size / 2, cy: size / 2, r, fill: "none", stroke: col, "stroke-width": w, "stroke-linecap": "round",
      "stroke-dasharray": `${(Math.min(100, Math.max(0, p)) / 100 * len).toFixed(1)} ${len.toFixed(1)}` }));
  return s;
}

// Боковая панель (на телефоне — снизу): тема; карточка клиента — своя, #drawer
const tpanel = h("aside", { class: "drawer", "aria-label": "Тема" });
document.body.append(tpanel);
function lookPanel() {
  closeMore(); closePal();
  const slider = (k, label, min, max, v, unit, cls = "") => {
    const val = h("b", {}, v + unit);
    const inp = h("input", { type: "range", min, max, value: v, class: cls || null, "aria-label": label, oninput: () => {
      LOOK[k] = +inp.value;
      if (k === "sat" && LOOK.hue == null) LOOK.hue = 156;
      if (k === "tint" && LOOK.bgHue == null) LOOK.bgHue = 220;
      val.textContent = inp.value + unit;
      if (k === "hue") sw.querySelectorAll(".swt").forEach((b) => b.classList.toggle("on", +b.dataset.h === LOOK.hue));
      applyLook(true);
    } });
    return h("label", { class: "sl" }, h("span", {}, label), val, inp);
  };
  let sw = null;
  function draw() {
    sw = h("div", { class: "swatches" }, SWATCH.map(([n, hh, sat]) => h("button", { class: "swt" + (LOOK.hue === hh ? " on" : ""),
      title: n, "aria-label": n, "data-h": hh, style: `background:hsl(${hh}, ${sat}%, 52%)`,
      onclick: () => { LOOK.hue = hh; LOOK.sat = sat; applyLook(true); draw(); } })));
    tpanel.replaceChildren(
      h("header", {}, h("span", { class: "ci" }, icon("sliders-horizontal")),
        h("div", {}, h("h2", {}, "Тема"), h("div", { class: "muted small" }, "для себя — запоминается на этом устройстве")),
        h("div", { class: "grow" }), h("button", { class: "ibtn", "aria-label": "Закрыть", onclick: closeLook }, icon("x"))),
      h("div", { class: "body" }, h("div", { class: "tbody" },
        h("div", {}, h("div", { class: "eyebrow" }, "режим"), h("div", { class: "even3" },
          [["dark", "Тёмная"], ["light", "Светлая"], ["auto", WEB ? "Системная" : "Как Telegram"]].map(([k, t]) =>
            h("button", { class: "chip" + (LOOK.mode === k ? " on" : ""), onclick: () => { LOOK.mode = k; applyLook(true); drawTop(); draw(); } }, t)))),
        h("div", {}, h("div", { class: "eyebrow" }, "акцент · кнопки, меню, переключатели"), sw),
        slider("hue", "Оттенок акцента", 0, 360, LOOK.hue != null ? LOOK.hue : 156, "°", "hue"),
        slider("sat", "Насыщенность", 20, 100, LOOK.sat, "%"),
        h("div", { class: "eyebrow tsep" }, "фон"),
        slider("bgHue", "Оттенок фона", 0, 360, LOOK.bgHue != null ? LOOK.bgHue : 220, "°", "hue"),
        slider("tint", "Тонировка", 0, 40, LOOK.tint, "%"),
        WEB ? h("div", {}, h("div", { class: "eyebrow tsep" }, "значок вкладки браузера"), h("div", { class: "even2", "data-name": "tab-icon" },
          [["logo", "Знак Тулзы"], ["flag", "Флаг страны"]].map(([k, t]) =>
            h("button", { class: "chip" + (LOOK.tab === k ? " on" : ""), onclick: () => { LOOK.tab = k; applyLook(true); favRefresh(); draw(); } }, t))),
        h("div", { class: "muted small", style: "margin-top:6px" }, "много вкладок с разными серверами — флаг страны и точка состояния awg0")) : null,
        h("div", { class: "eyebrow tsep" }, "форма и размер"),
        slider("rb", "Скругление углов", 0, 24, LOOK.rb, " px"),
        slider("zoom", "Масштаб", ZOOM_MIN, ZOOM_MAX, LOOK.zoom, "%"),
        h("div", { class: "tg", role: "switch", "aria-checked": String(!!LOOK.grid), "aria-label": "Клетка на фоне",
          onclick: () => { LOOK.grid = !LOOK.grid; applyLook(true); draw(); } },
        h("div", {}, h("b", {}, "Клетка на фоне"), h("span", {}, "тонкая сетка, как на миллиметровке")), h("i", { class: "switch" + (LOOK.grid ? " on" : "") })),
        h("div", { class: "prev" }, h("div", { class: "eyebrow" }, "предпросмотр"),
          h("div", { class: "even2" }, h("button", { class: "btn-primary" }, icon("plus"), "Новый клиент"), h("button", {}, icon("download"), "Экспорт")),
          h("div", { class: "prow" }, h("span", { class: "chip on" }, "В сети ", h("span", { class: "n" }, "4")), pill("онлайн", "ok"),
            pill("92%", "warn"), h("i", { class: "switch on" }), ringSvg(64, 26, 4))),
        h("div", { class: "even2" },
          h("button", { onclick: () => { LOOK = Object.assign({}, LOOK_DEF, { mode: LOOK.mode }); applyLook(true); drawTop(); draw(); toast("Вид по умолчанию"); } },
            icon("rotate-ccw"), "Сбросить"),
          h("button", { class: "btn-primary", onclick: closeLook }, "Готово")))));
  }
  draw();
  tpanel.classList.add("on");
  syncScrim();
  trapOpen(tpanel);
}
function closeLook() { tpanel.classList.remove("on"); syncScrim(); trapClose(tpanel); }

const SUPPORT_URL = "https://t.me/awgToolza/156/157";
// Меню бота утонуло под конфигами — бот присылает его вниз чата, панель закрывается
function menuToChat() {
  return busy(null, async () => {
    await post("/api/bot/menu");
    haptic();
    if (tg && tg.close) tg.close(); else toast("Меню — внизу чата с ботом");
  });
}
// ── Каркас: шапка, лента слева (веб-панель на ПК), нижняя панель и «Ещё» ──
const NAV = [
  ["/", "house", "Обзор"], ["/clients", "users", "Клиенты"], ["/tunnels", "waypoints", "Туннели"], ["/server", "server", "Сервер"],
  ["/diag", "stethoscope", "Диагностика"], ["/update", "circle-arrow-up", "Обновление"], ["/backup", "archive", "Бэкапы"],
  ["/wgobf", "shield", "Обфускатор"], ["/bot", "bot", "Бот"],
];
const topEl = document.getElementById("top"), railEl = document.getElementById("rail"), tabEl = document.getElementById("tabbar"),
  moreEl = document.getElementById("more"), scrim = document.getElementById("scrim"), drawerEl = document.getElementById("drawer");
const curPath = () => location.hash.slice(1) || "/";
// Срок показываем, как раньше, у незаблокированного (истёкший до прохода таймера —
// «истёк», заметно, если таймер не блокирует), а ещё у заблокированного за трафик
// с будущим сроком: блок держит лимит, срок остаётся в силе
const expLive = (c) => !!c.expires && (!c.blocked || (c.blocked_by === "traffic" && c.expires > Date.now() / 1000));
// Битый %-код в адресе (#/client/%E0%A4) — decodeURIComponent бросает; такой путь считается ненайденным
const badPath = (p) => { try { decodeURIComponent(p); return false; } catch (_) { return true; } };
const isOn = (p) => {
  const c = curPath();
  return p === "/" ? c === "/" : c === p || c.startsWith(p + "/") || (p === "/clients" && /^\/(client\/|add$|bulk$)/.test(c))
    || (p === "/diag" && c.startsWith("/log/"));
};
// Панель открыта по делу: в Telegram — с подписью, в веб-панели — после входа
const inApp = () => (WEB ? !!S.me : !!(tg && tg.initData));
const railOn = () => inApp() && desk();
const hasUpd = () => !!S.update && S.update !== S.version;
// Имя и адрес сервера в шапке можно скрыть (для скриншотов и показа экрана) —
// заодно порт на схеме маршрутов. Лента на ПК — с подписями или узкая, иконками
const srvHidden = () => pref("hide-srv", "") === "1";
const railWide = () => pref("rail", "wide") !== "narrow";
function toggleSrvHidden() { setPref("hide-srv", srvHidden() ? "" : "1"); drawTop(); window.dispatchEvent(new Event("resize")); }
function toggleRail() { setPref("rail", railWide() ? "narrow" : "wide"); drawTop(); window.dispatchEvent(new Event("resize")); }
const logoImg = (cls) => h("img", { class: "tz" + (cls ? " " + cls : ""), src: tzIcon(), alt: "" });

// Знак-название: крупное AWG на всю высоту, справа «toolza» и строка версии.
// Буквы меряются в браузере (canvas, тот же шрифт): верх AWG — по верху «toolza»,
// низ — по низу версии; версия и BETA растянуты ровно по ширине «toolza».
function lockupEl(rail) {
  const cv = lockupEl.c || (lockupEl.c = document.createElement("canvas").getContext("2d"));
  const css = getComputedStyle(document.documentElement);
  const SANS = (css.getPropertyValue("--sans") || "system-ui").trim().replace(/"/g, "'");
  const MONO = (css.getPropertyValue("--mono") || "monospace").trim().replace(/"/g, "'");
  // Меряем в 10 раз крупнее и делим: без округления метрик мелкого кегля
  const m = (txt, font) => { cv.font = font.replace(/([\d.]+)px/, (_, n) => n * 10 + "px"); const r = cv.measureText(txt);
    // Без точных границ букв (старый движок) — по ширине и кеглю
    if (r.actualBoundingBoxAscent == null) { const px = +(/([\d.]+)px/.exec(cv.font) || [0, 100])[1];
      return { l: 0, r: r.width / 10, a: px * 0.72 / 10, d: px * 0.02 / 10 }; }
    return { l: r.actualBoundingBoxLeft / 10, r: r.actualBoundingBoxRight / 10, a: r.actualBoundingBoxAscent / 10, d: r.actualBoundingBoxDescent / 10 }; };
  // На телефоне чуть ниже: рядом поиск и тема
  // В ленте с подписями и на самых узких телефонах — ещё ниже: рядом знак и флаг
  const mq = (q) => !!window.matchMedia && matchMedia(q).matches;
  const tiny = rail || mq("(max-width: 380px)"), small = tiny || mq("(max-width: 720px)");
  const H = tiny ? 24 : small ? 27 : 32, GAP = tiny ? 5 : small ? 6 : 8, f2 = `700 ${tiny ? 8.5 : small ? 9 : 10}px ${MONO}`;
  const ver = S.version || "", up = hasUpd() ? "↑" : "", beta = S.channel === "beta" ? "BETA" : "";
  const mv = m(ver || " ", f2), mu = m(up || " ", f2), mb = m(beta || " ", f2);
  const gU = rail ? 3 : 4, gB = rail ? 6 : 10;
  const need = ver ? mv.l + mv.r + (up ? gU + mu.l + mu.r : 0) + (beta ? gB + mb.l + mb.r : 0) : 0;
  // «toolza» растёт до ширины строки версии, но не выше, чем позволяет зазор над ней:
  // иначе версия прилипает к буквам. Не дотянулась — строка версии чуть шире слова
  const d2 = Math.max(0, mv.d, mb.d), GAPV = small ? 4 : 5, maxA = H - d2 - Math.max(mv.a, mb.a) - GAPV;
  let F1 = tiny ? 14 : small ? 16 : 19, m1 = m("toolza", `800 ${F1}px ${SANS}`);
  while (ver && m1.l + m1.r < need && F1 < 32) {
    const nx = m("toolza", `800 ${F1 + 0.5}px ${SANS}`);
    if (nx.a > maxA) break;
    F1 += 0.5; m1 = nx;
  }
  if (ver) while (m1.a > maxA && F1 > 12) { F1 -= 0.5; m1 = m("toolza", `800 ${F1}px ${SANS}`); }
  const y1 = m1.a, y2 = H - d2;
  const a100 = m("AWG", `800 100px ${SANS}`), FA = H * 100 / (a100.a + a100.d), ma = m("AWG", `800 ${FA}px ${SANS}`);
  const xA = ma.l, L2 = xA + ma.r + GAP, x1 = L2 + m1.l, R1 = Math.max(x1 + m1.r, L2 + need);
  const xv = L2 + mv.l, xu = L2 + mv.l + mv.r + gU + mu.l, xb = R1 - mb.r, W = Math.ceil(R1) + 1;
  // В ленте место рядом со знаком — 144px (лента 220px): длинная строка «версия ↑ BETA»
  // и шрифты пошире (Windows) — знак-название целиком ужимается, а не обрезается краем ленты
  const k = rail && W > 144 ? 144 / W : 1;
  const el = svg("svg", { class: "lockup", viewBox: `0 -1 ${W} ${H + 2}`, width: (W * k).toFixed(1), height: ((H + 2) * k).toFixed(1), role: "img",
    "aria-label": ["AWG toolza", ver, beta.toLowerCase()].filter(Boolean).join(" ") });
  const t = (x, y, font, fill, txt) => { const e = svg("text", { x: x.toFixed(2), y: y.toFixed(2), style: `font:${font};fill:${fill}` });
    e.textContent = txt; el.append(e); };
  t(xA, ma.a, `800 ${FA.toFixed(2)}px ${SANS}`, "var(--text)", "AWG");
  t(x1, ver ? y1 : (H + m1.a - m1.d) / 2, `800 ${F1}px ${SANS}`, "var(--acc)", "toolza");
  if (ver) t(xv, y2, f2, "var(--muted)", ver);
  if (up) t(xu, y2, f2, "var(--acc)", up);
  if (beta) t(xb, y2, f2, "var(--amber)", beta);
  return el;
}

// ── Страна сервера: флаг в шапке ─────────────────────────
// Свои маленькие SVG: Windows и Telegram Desktop не рисуют эмодзи-флаги (там
// вместо флага две буквы). Страны, где чаще всего стоят VPS; у остальных —
// код страны буквами. h — полосы сверху вниз, v — слева направо,
// x — скандинавский крест (фон, крест, крест внутри)
const FLAGS = {
  NL: "h:#AE1C28,#fff,#21468B", DE: "h:#000,#DD0000,#FFCE00", RU: "h:#fff,#0039A6,#D52B1E", LV: "h:#9E3039,#9E3039,#fff,#9E3039,#9E3039",
  LT: "h:#FDB913,#006A44,#C1272D", EE: "h:#0072CE,#000,#fff", AT: "h:#C8102E,#fff,#C8102E", HU: "h:#CE2939,#fff,#477050",
  BG: "h:#fff,#00966E,#D62612", UA: "h:#0057B7,#FFD700", PL: "h:#fff,#DC143C", LU: "h:#EA141D,#fff,#51ADDA",
  AM: "h:#D90012,#0033A0,#F2A800", ES: "h:#AA151B,#F1BF00,#F1BF00,#AA151B", RS: "h:#C6363C,#0C4076,#fff", AZ: "h:#0092BC,#E4002B,#00AF66",
  BY: "h:#C8313E,#C8313E,#4AA657", FR: "v:#002395,#fff,#ED2939", IT: "v:#009246,#fff,#CE2B37", BE: "v:#000,#FDDA24,#EF3340",
  IE: "v:#169B62,#fff,#FF883E", RO: "v:#002B7F,#FCD116,#CE1126", MD: "v:#0046AE,#FFD200,#CC092F",
  FI: "x:#fff,#002F6C", SE: "x:#006AA7,#FECC00", DK: "x:#C8102E,#fff", NO: "x:#BA0C2F,#fff,#00205B", IS: "x:#02529C,#fff,#DC1E35",
  US: () => `<rect width="30" height="20" fill="#fff"/>${[0, 1, 2, 3, 4, 5, 6].map((i) =>
    `<rect y="${(i * 40 / 13).toFixed(2)}" width="30" height="1.54" fill="#B22234"/>`).join("")}<rect width="13" height="10.77" fill="#3C3B6E"/>`,
  GB: () => `<rect width="30" height="20" fill="#012169"/><path d="M0,0 30,20M30,0 0,20" stroke="#fff" stroke-width="4"/>
    <path d="M0,0 30,20M30,0 0,20" stroke="#C8102E" stroke-width="1.4"/><path d="M15,0V20M0,10H30" stroke="#fff" stroke-width="6"/>
    <path d="M15,0V20M0,10H30" stroke="#C8102E" stroke-width="3.4"/>`,
  CH: () => `<rect width="30" height="20" fill="#DA291C"/><rect x="13" y="4" width="4" height="12" fill="#fff"/><rect x="9" y="8" width="12" height="4" fill="#fff"/>`,
  JP: () => `<rect width="30" height="20" fill="#fff"/><circle cx="15" cy="10" r="6" fill="#BC002D"/>`,
  TR: () => `<rect width="30" height="20" fill="#E30A17"/><circle cx="11" cy="10" r="5" fill="#fff"/><circle cx="12.3" cy="10" r="4" fill="#E30A17"/>
    <polygon points="${starPts(17.6, 10, 2.4)}" fill="#fff"/>`,
  KZ: () => `<rect width="30" height="20" fill="#00AFCA"/><circle cx="15" cy="9" r="3.8" fill="#FEC50C"/>`,
  CZ: () => `<rect width="30" height="10" fill="#fff"/><rect y="10" width="30" height="10" fill="#D7141A"/><path d="M0,0 15,10 0,20Z" fill="#11457E"/>`,
  CA: () => `<rect width="30" height="20" fill="#fff"/><rect width="7.5" height="20" fill="#D80621"/><rect x="22.5" width="7.5" height="20" fill="#D80621"/>
    <polygon points="${starPts(15, 10.3, 4)}" fill="#D80621"/>`,
  GE: () => `<rect width="30" height="20" fill="#fff"/><rect x="12.5" width="5" height="20" fill="#FF0000"/><rect y="7.5" width="30" height="5" fill="#FF0000"/>`,
  SG: () => `<rect width="30" height="10" fill="#EF3340"/><rect y="10" width="30" height="10" fill="#fff"/><circle cx="7" cy="5" r="3.2" fill="#fff"/>
    <circle cx="8.4" cy="5" r="3" fill="#EF3340"/>`,
  PT: () => `<rect width="12" height="20" fill="#046A38"/><rect x="12" width="18" height="20" fill="#DA291C"/><circle cx="12" cy="10" r="3.5" fill="#FFE900"/>`,
  IN: () => `${flagBody("h:#FF9933,#fff,#138808")}<circle cx="15" cy="10" r="2.4" fill="none" stroke="#06038D" stroke-width=".8"/>`,
  GR: () => `${flagBody("h:#0D5EAF,#fff,#0D5EAF,#fff,#0D5EAF,#fff,#0D5EAF,#fff,#0D5EAF")}<rect width="11.1" height="11.1" fill="#0D5EAF"/>
    <rect x="4.45" width="2.2" height="11.1" fill="#fff"/><rect y="4.45" width="11.1" height="2.2" fill="#fff"/>`,
  IL: () => `<rect width="30" height="20" fill="#fff"/><rect y="2" width="30" height="3" fill="#0038B8"/><rect y="15" width="30" height="3" fill="#0038B8"/>
    <path d="M15,6.6 18,11.8 12,11.8ZM15,13.4 12,8.2 18,8.2Z" fill="none" stroke="#0038B8" stroke-width=".9"/>`,
  AE: () => `${flagBody("h:#00732F,#fff,#000")}<rect width="8" height="20" fill="#FF0000"/>`,
};
const COUNTRY = { NL: "Нидерланды", DE: "Германия", RU: "Россия", LV: "Латвия", LT: "Литва", EE: "Эстония", AT: "Австрия", HU: "Венгрия",
  BG: "Болгария", UA: "Украина", PL: "Польша", LU: "Люксембург", AM: "Армения", ES: "Испания", RS: "Сербия", AZ: "Азербайджан",
  BY: "Беларусь", FR: "Франция", IT: "Италия", BE: "Бельгия", IE: "Ирландия", RO: "Румыния", MD: "Молдова", FI: "Финляндия",
  SE: "Швеция", DK: "Дания", NO: "Норвегия", IS: "Исландия", US: "США", GB: "Великобритания", CH: "Швейцария", JP: "Япония",
  TR: "Турция", KZ: "Казахстан", CZ: "Чехия", CA: "Канада", GE: "Грузия", SG: "Сингапур", PT: "Португалия", IN: "Индия",
  GR: "Греция", IL: "Израиль", AE: "ОАЭ" };
function countryName(cc) {
  if (COUNTRY[cc]) return COUNTRY[cc];
  try { if (window.Intl && Intl.DisplayNames) return new Intl.DisplayNames(["ru"], { type: "region" }).of(cc) || cc; } catch (_) { /* старый движок */ }
  return cc;
}
function starPts(cx, cy, R) {
  const p = [];
  for (let i = 0; i < 10; i++) {
    const r = i % 2 ? R * 0.4 : R, a = Math.PI / 5 * i - Math.PI / 2;
    p.push(`${(cx + r * Math.cos(a)).toFixed(2)},${(cy + r * Math.sin(a)).toFixed(2)}`);
  }
  return p.join(" ");
}
function flagBody(f) {
  if (typeof f === "function") return f();
  const [k, list] = f.split(":"), c = list.split(","), n = c.length;
  // Полосы внахлёст на долю пикселя: без светлых щелей между ними при масштабе
  if (k === "h") return c.map((col, i) => `<rect y="${(20 * i / n).toFixed(2)}" width="30" height="${(20 / n + 0.1).toFixed(2)}" fill="${col}"/>`).join("");
  if (k === "v") return c.map((col, i) => `<rect x="${(30 * i / n).toFixed(2)}" width="${(30 / n + 0.1).toFixed(2)}" height="20" fill="${col}"/>`).join("");
  return `<rect width="30" height="20" fill="${c[0]}"/><rect x="8" width="5" height="20" fill="${c[1]}"/><rect y="7.5" width="30" height="5" fill="${c[1]}"/>`
    + (c[2] ? `<rect x="9.25" width="2.5" height="20" fill="${c[2]}"/><rect y="8.75" width="30" height="2.5" fill="${c[2]}"/>` : "");
}
function flagEl(cc, w) {
  if (!FLAGS[cc]) return null;
  const el = svg("svg", { class: "flag", viewBox: "0 0 30 20", width: w, height: Math.round(w * 2 / 3), role: "img", "aria-label": countryName(cc) });
  el.innerHTML = flagBody(FLAGS[cc]);
  return el;
}
const srvState = (st) => { const s = st.server || {}; return !s.exists ? "сервер не создан" : s.up ? "awg0 работает" : "awg0 не поднят"; };
const srvPulse = (st) => { const s = st.server || {}; return !s.exists ? "off" : s.up ? "" : "bad"; };

// О сервере: страна, имя, адрес, awg0, протокол, аптайм, версия. На ПК — окно
// под флагом, на телефоне — лист снизу. «Скрыть адрес» — тут же, окно не закрывается
function serverInfo(anchor) {
  closeMore(); closePal();
  const row = (k, v, cls) => h("div", { class: "sir" }, h("span", {}, k), h("b", { class: cls || null, title: v }, v));
  let close = null;
  const box = h("div", { class: "sheet sinfo", "aria-label": "О сервере", "data-name": "server-info" });
  const fill = () => {
    const st = S.status || {}, s = st.server || {}, cc = st.country || "", hide = srvHidden(), up = uptimeParts(st.uptime);
    box.replaceChildren(
      h("div", { class: "sih" }, flagEl(cc, 42) || h("span", { class: "cc big" }, cc || icon("globe")),
        h("div", {}, h("h3", {}, cc ? countryName(cc) : "Страна не определена"),
          h("div", { class: "muted small" }, h("i", { class: "pulse " + srvPulse(st) }), srvState(st)))),
      h("div", { class: "sil" },
        row("имя", hide ? "скрыто" : st.host || "—", hide ? "hid" : null),
        row("адрес", !s.exists ? "—" : hide ? "скрыт" : s.endpoint || st.ip || "—", "mono" + (hide ? " hid" : "")),
        // Скрыт адрес — и порт: по нему сервер находится так же, как по адресу
        s.exists ? row("протокол", `AWG ${s.proto || "?"}` + (hide ? "" : ` · ${s.port || "?"}/udp`)) : null,
        s.exists ? row("клиенты", `${s.online || 0} в сети из ${s.clients || 0}`) : null,
        row("аптайм", up[0] + " " + up[1] + (up[2] != null ? ` ${up[2]} ${up[3]}` : "")),
        row("система", st.os || "—"),
        row("AWG Toolza", (S.version || "?") + (S.channel === "beta" ? " · бета" : "") + (hasUpd() ? ` · есть ${S.update}` : ""))),
      h("div", { class: "even2" },
        h("button", { class: "seye", "aria-pressed": String(hide), onclick: () => {
          toggleSrvHidden(); fill();           // drawTop() сам переводит возврат фокуса на новый флаг
          const b = box.querySelector(".seye");
          if (b) b.focus();
        } }, icon(hide ? "eye" : "eye-off"), hide ? "Показать адрес" : "Скрыть адрес"),
        h("button", { class: "btn-primary", onclick: () => { close(); go("/server"); } }, icon("server"), "Сервер")));
  };
  fill();
  close = sheetOpen(box);
  // На широком экране — выпадает из кнопки, а не окном посреди экрана или снизу
  const vw = document.documentElement.clientWidth;
  if (anchor && box.parentNode && (railOn() || vw > 720)) {
    const r = anchor.getBoundingClientRect();
    box.parentNode.classList.add("pop-bg");
    box.classList.add("pop");
    box.style.top = Math.round(r.bottom + 8) + "px";
    if (r.left + r.width / 2 < vw / 2) box.style.left = Math.round(Math.max(12, r.left)) + "px";
    else box.style.right = Math.round(Math.max(12, vw - r.right)) + "px";
  }
}

function drawTop() {
  const app = inApp();
  document.body.classList.toggle("rail-on", railOn());
  document.body.classList.toggle("rail-wide", railOn() && railWide());
  document.body.classList.toggle("bare", !app);
  // Сервер в шапке — флаг страны VPS и точка состояния; имя, адрес и остальное —
  // во всплывающем окне по нажатию на флаг
  const st = S.status || {}, s = st.server || {}, cc = st.country || "";
  // Страна и состояние awg0 — и в подписи для чтения с экрана: точка состояния цветом ничего не говорит
  const tip = ["О сервере", cc ? countryName(cc) : null, srvState(st)].filter(Boolean).join(" · ");
  const flag = app && S.status ? h("button", { class: "cflag", "aria-label": tip, title: tip, onclick: (ev) => serverInfo(ev.currentTarget) },
  flagEl(cc, 24) || h("span", { class: "cc" }, cc || icon("globe")), h("i", { class: "pulse " + srvPulse(st) })) : null;
  const upd = hasUpd();
  topEl.replaceChildren(...[
    h("a", { class: "lock", title: upd ? `AWG Toolza ${S.version} · доступна ${S.update}` : "AWG Toolza",
      onclick: app ? () => go(upd && curPath() === "/" ? "/update" : "/") : null }, logoImg(), lockupEl()),
    flag, h("div", { class: "grow" }),
    app ? h("button", { class: "kbar", title: "Раздел, клиент или действие (Ctrl+K)", onclick: openPal },
      icon("search"), h("span", {}, "Команда или клиент…"), h("kbd", {}, "Ctrl K")) : null,
    app ? h("button", { class: "ibtn", title: "Тема и цвета", "aria-label": "Тема", onclick: lookPanel },
      icon(themeNow() === "dark" ? "sun" : "moon")) : null,
    app && WEB ? h("button", { class: "me", title: S.me.name || "Аккаунт", "aria-label": "Аккаунт", onclick: accountMenu },
      String(S.me.name || "A").slice(0, 1).toUpperCase()) : null,
    app ? null : supportButton()].filter(Boolean));
  drawNav();
  // Флаг в шапке — новый: окно, открытое по флагу, вернёт фокус ему, а не в пустоту
  const nf = topEl.querySelector(".cflag");
  traps.forEach((t) => { if (nf && t.back && t.back.classList && t.back.classList.contains("cflag") && !document.body.contains(t.back)) t.back = nf; });
}

// Лента (ПК) и нижняя панель с «Ещё» (телефон, Mini App) — по текущему адресу
const TABS = NAV.slice(0, 4);
const MORE = () => [...NAV.slice(4), ["look", "sliders-horizontal", "Тема"],
  ...(WEB ? [["/account", "user", "Аккаунт"], ["logout", "door-open", "Выйти"]]
    : [["chat", "message-square-text", "Меню бота"], ["support", "heart", "Поддержать"]])];
function drawNav() {
  const app = inApp(), rail = railOn();
  if (rail) {
    // С подписями — текст рядом с иконкой; узкая — подсказка при наведении
    const wide = railWide();
    const a = (p, ic, t, onclick, cls) => h("a", { href: onclick ? "#" : "#" + p,
      class: [cls, !onclick && isOn(p) ? "on" : null].filter(Boolean).join(" ") || null, "aria-label": t,
      onclick: (ev) => { if (onclick) { ev.preventDefault(); onclick(); } else sameTab(ev, p); } },
      icon(ic), h("span", { class: wide ? "lbl" : "tip" }, t), p === "/update" && hasUpd() ? h("i", { class: "badge" }) : null);
    // С подписями — рядом со знаком и название с версией (в шапке его тогда нет)
    const upd = hasUpd();
    railEl.replaceChildren(...[h("a", { class: "logo", href: "#/", "aria-label": "Обзор",
      title: upd ? `AWG Toolza ${S.version} · доступна ${S.update}` : "AWG Toolza",
      onclick: (ev) => { if (upd && curPath() === "/") { ev.preventDefault(); go("/update"); } } }, logoImg(), wide ? lockupEl(true) : null),
      ...NAV.map(([p, ic, t]) => a(p, ic, t)), h("div", { class: "sp" }),
      a("", "sliders-horizontal", "Тема", lookPanel),
      WEB ? a("/account", "user", "Аккаунт") : null,
      WEB ? a("", "door-open", "Выйти", logout) : null,
      a("", "menu", wide ? "Свернуть меню" : "Меню с подписями", toggleRail, "burger")].filter(Boolean));
  } else {
    railEl.replaceChildren();
  }
  const tabs = app && !rail;
  tabEl.style.display = tabs ? "" : "none";
  if (!tabs) { tabEl.replaceChildren(); closeMore(); return; }
  const more = MORE();
  const moreOn = more.some(([p]) => p.startsWith("/") && isOn(p));
  tabEl.replaceChildren(...TABS.map(([p, ic, t]) => h("a", { href: "#" + p, class: isOn(p) ? "on" : null,
    onclick: (ev) => sameTab(ev, p) }, icon(ic), t)),
    h("a", { class: moreOn ? "on" : null, role: "button", onclick: toggleMore }, icon("layout-grid"), "Ещё",
      hasUpd() ? h("i", { class: "tdot" }) : null));
  moreEl.replaceChildren(h("div", { class: "mg" }, more.map(([p, ic, t]) => h("a", {
    class: p.startsWith("/") && isOn(p) ? "on" : null, role: "button", onclick: () => moreGo(p) },
  h("span", { class: "mi" }, icon(ic), p === "/update" && hasUpd() ? h("i", { class: "badge" }) : null), t))));
}
// Нажали раздел, который уже открыт: адрес тот же, hashchange не будет — обновить экран
function sameTab(ev, p) { if (curPath() === p) { ev.preventDefault(); render(); } }
function moreGo(p) {
  closeMore();
  if (p === "look") lookPanel();
  else if (p === "logout") logout();
  else if (p === "chat") menuToChat();
  else if (p === "support") openSupport();
  else go(p);
}
function toggleMore() { if (moreEl.classList.contains("on")) closeMore(); else { moreEl.classList.add("on"); syncScrim(); } }
function closeMore() { moreEl.classList.remove("on"); syncScrim(); }
function syncScrim() {
  scrim.classList.toggle("on", moreEl.classList.contains("on") || drawerEl.classList.contains("on") || tpanel.classList.contains("on"));
}
scrim.addEventListener("click", () => {
  if (tpanel.classList.contains("on")) closeLook();
  else if (moreEl.classList.contains("on")) closeMore();
  else if (drawerEl.classList.contains("on")) go("/clients");
});

const openSupport = () => {
  if (tg && tg.initData && tg.openTelegramLink) tg.openTelegramLink(SUPPORT_URL); else window.open(SUPPORT_URL, "_blank", "noopener");
};
const supportButton = () => h("button", { class: "ibtn", "aria-label": "Поддержать", title: "Поддержать", onclick: openSupport }, icon("heart"));
async function accountMenu() {
  const v = await sheet(S.me && S.me.name ? S.me.name : "Аккаунт", [{ label: "👤 Аккаунт и безопасность", value: "/account" },
    { label: "🎨 Тема и цвета", value: "look" }, { label: "🚪 Выйти", value: "logout" }]);
  if (v === "look") lookPanel(); else if (v === "logout") logout(); else if (v) go(v);
}

// ── Командная палитра: Ctrl+K — раздел, клиент или действие ──
const AWG0_RESTART = "Перезапустить awg0? Клиенты переподключатся сами за несколько секунд.";
const palEl = document.getElementById("pal"), palQ = document.getElementById("palq"), palL = document.getElementById("pall");
let palItems = [], palSel = 0;
function palCatalog() {
  const dark = themeNow() === "dark";
  const items = NAV.map(([p, ic, t]) => ({ ic, t, g: "раздел", run: () => go(p) }));
  items.push(
    { ic: "plus", t: "Новый клиент", g: "действие", run: () => go("/add") },
    { ic: "users", t: "Несколько клиентов сразу", g: "действие", run: () => go("/bulk") },
    { ic: "download", t: WEB ? "Скачать все конфиги архивом" : "Все конфиги архивом в чат", g: "действие",
      run: () => busy(null, () => deliver({ what: "export" }, "Архив всех конфигов — в чате с ботом")) },
    { ic: "refresh-cw", t: "Перезапустить awg0", g: "действие",
      run: () => quickAsk(null, AWG0_RESTART, "awg0 перезапущен", ["server", "restart"], () => {}) },
    { ic: "stethoscope", t: "Проверить сервер", g: "действие", run: () => go("/diag") },
    { ic: "sliders-horizontal", t: "Тема и цвета", g: "вид", run: lookPanel },
    { ic: dark ? "sun" : "moon", t: dark ? "Светлая тема" : "Тёмная тема", g: "вид",
      run: () => { LOOK.mode = dark ? "light" : "dark"; applyLook(true); drawTop(); } });
  if (WEB) items.push({ ic: "user", t: "Аккаунт и пароль", g: "веб-панель", run: () => go("/account") },
    { ic: "door-open", t: "Выйти", g: "веб-панель", run: logout });
  else items.push({ ic: "message-square-text", t: "Меню бота в чат", g: "бот", run: menuToChat });
  for (const c of (S.clients && S.clients.rows) || []) {
    items.push({ ic: "user", t: c.name, g: c.blocked ? blockedWord(c) : c.online ? "онлайн" : "клиент",
      q: `${c.name} ${c.ip} ${c.note || ""}`, run: () => go("/client/" + encodeURIComponent(c.name)) });
  }
  return items;
}
function drawPal() {
  const q = palQ.value.trim().toLowerCase();
  palItems = palCatalog().filter((x) => !q || (x.q || x.t).toLowerCase().includes(q) || x.g.includes(q)).slice(0, 50);
  palSel = Math.min(palSel, Math.max(0, palItems.length - 1));
  palL.replaceChildren(...(palItems.length ? palItems.map((x, i) => h("li", { class: i === palSel ? "on" : null,
    onclick: () => runPal(i), onmousemove: () => { if (palSel !== i) { palSel = i; markPal(); } } },
  icon(x.ic), x.t, h("span", { class: "g2" }, x.g))) : [h("li", { class: "muted" }, "Ничего не нашлось")]));
}
function markPal() {
  [...palL.children].forEach((li, i) => li.classList.toggle("on", i === palSel));
  const on = palL.children[palSel];
  if (on && on.scrollIntoView) on.scrollIntoView({ block: "nearest" });
}
function runPal(i) { const x = palItems[i]; if (!x) return; closePal(); x.run(); }
function openPal() {
  if (!inApp()) return;
  closeMore();
  palSel = 0; palQ.value = "";
  palEl.classList.add("on"); drawPal(); trapOpen(palEl.querySelector(".w"), palQ);
  if (!S.clients) loadClients().then(() => { if (palEl.classList.contains("on")) drawPal(); }).catch(() => {});
}
function closePal() { palEl.classList.remove("on"); trapClose(palEl.querySelector(".w")); }
palQ.addEventListener("input", () => { palSel = 0; drawPal(); });
palQ.addEventListener("keydown", (ev) => {
  if (ev.key === "ArrowDown") { ev.preventDefault(); palSel = Math.min(palItems.length - 1, palSel + 1); markPal(); }
  else if (ev.key === "ArrowUp") { ev.preventDefault(); palSel = Math.max(0, palSel - 1); markPal(); }
  else if (ev.key === "Enter") { ev.preventDefault(); runPal(palSel); }
});
palEl.addEventListener("click", (ev) => { if (ev.target === palEl) closePal(); });
document.addEventListener("keydown", (ev) => {
  if ((ev.ctrlKey || ev.metaKey) && (ev.key === "k" || ev.key === "K" || ev.key === "л" || ev.key === "Л")) {
    ev.preventDefault(); palEl.classList.contains("on") ? closePal() : openPal();
  } else if (ev.key === "Escape") {
    const sheetBg = [...document.querySelectorAll(".sheet-bg")].pop();
    if (sheetBg) sheetBg.close ? sheetBg.close() : sheetBg.remove();   // как нажатие мимо окна — «Отмена»
    else if (palEl.classList.contains("on")) closePal();
    else if (tpanel.classList.contains("on")) closeLook();
    else if (moreEl.classList.contains("on")) closeMore();
    else if (drawerEl.classList.contains("on")) go("/clients");
  }
});

// Одна подсказка за раз: новая сменяет прежнюю, а не ложится поверх
let toastEl = null;
function toast(text, ms = 2000) {
  if (toastEl) toastEl.remove();
  const t = toastEl = h("div", { class: "toast" }, text);
  document.body.append(t);
  setTimeout(() => { t.remove(); if (toastEl === t) toastEl = null; }, ms);
}
// showAlert/showConfirm — это showPopup: текст длиннее 256 символов не
// обрезается, а бросает WebAppPopupParamInvalid, и окно не появляется вовсе.
// Режем середину: последний абзац — это вопрос («…Применить?»), он остаётся
const POPUP_MAX = 256;
function popupText(text) {
  if (text.length <= POPUP_MAX) return text;
  const i = text.lastIndexOf("\n"), tail = i > 0 ? text.slice(i) : "";
  if (tail && tail.length <= POPUP_MAX - 60) return text.slice(0, POPUP_MAX - tail.length - 1).replace(/\s+$/, "") + "…" + tail;
  return text.slice(0, 60).replace(/\s+$/, "") + "…" + text.slice(text.length - (POPUP_MAX - 61));
}
// Хвост журнала к ошибке — без строк, повторяющих её текст («× нет места» при
// ошибке «нет места»): префиксы журнала awg2 при сравнении не в счёт
function logTail(e, n) {
  const msg = String(e.message || "").trim();
  return (e.log || "").trim().split("\n").filter((l) => l.trim().replace(/^[×→▲√]\s*/, "") !== msg)
    .slice(-n).join("\n").trim();
}
function fail(e) {
  if (e.login) return;                     // сессия кончилась — на экране уже форма входа
  haptic("error");
  const tail = logTail(e, 6);
  const text = "❌ " + e.message + (tail ? "\n\n" + tail : "");
  // Без Telegram (веб-панель) — тем же листом, что и длинная ошибка, а не окном браузера
  if (!tg || !tg.showAlert) return logSheet("❌ " + e.message, tail || false);
  // Длинная ошибка с хвостом журнала — листом снизу, целиком
  if (text.length <= POPUP_MAX) tg.showAlert(text); else logSheet("❌ " + (e.message || "Ошибка").slice(0, 80), text);
}
function confirmTg(text) {
  text = popupText(text);
  return new Promise((ok) => (tg && tg.showConfirm ? tg.showConfirm(text, ok) : ok(window.confirm(text))));
}
// Окно поверх страницы (лист, палитра, карточка справа, «Тема»): фокус —
// внутрь, Tab не уходит на страницу под ним, закрыли — фокус обратно к кнопке,
// которая его открыла
const traps = [];
const focusables = (el) => [...el.querySelectorAll("button, [href], input, select, textarea, [tabindex]:not([tabindex='-1'])")]
  .filter((x) => !x.disabled && x.getClientRects().length);
function trapOpen(el, first) {
  el.setAttribute("role", "dialog"); el.setAttribute("aria-modal", "true");
  if (!traps.some((t) => t.el === el)) traps.push({ el, back: document.activeElement });
  const f = first || focusables(el)[0];
  if (f) f.focus();
}
function trapClose(el) {
  const i = traps.findIndex((t) => t.el === el);
  if (i < 0) return;
  const back = traps.splice(i, 1)[0].back;
  // В Telegram фокус в поле ввода вернул бы экранную клавиатуру — только кнопкам
  if (back && back.focus && document.body.contains(back) && (WEB || !/^(INPUT|TEXTAREA|SELECT)$/.test(back.tagName))) back.focus();
}
document.addEventListener("keydown", (ev) => {
  if (ev.key !== "Tab" || !traps.length) return;
  const el = traps[traps.length - 1].el, f = focusables(el), a = document.activeElement;
  if (!f.length) { ev.preventDefault(); return; }
  if (!el.contains(a)) { ev.preventDefault(); f[0].focus(); }
  else if (ev.shiftKey && a === f[0]) { ev.preventDefault(); f[f.length - 1].focus(); }
  else if (!ev.shiftKey && a === f[f.length - 1]) { ev.preventDefault(); f[0].focus(); }
});
// Лист снизу (на ПК — окно по центру): мимо него, Esc, «Отмена» и смена экрана
// закрывают; onClose(nav) — nav = закрыт сменой экрана (render)
function sheetOpen(box, onClose) {
  const bg = h("div", { class: "sheet-bg", onclick: (ev) => { if (ev.target === bg) close(); } }, box);
  function close(nav) {
    if (!bg.parentNode) return;
    bg.remove(); trapClose(box);
    if (onClose) onClose(!!nav);
  }
  bg.close = close;
  if (!box.hasAttribute("aria-label")) { const t = box.querySelector("h3"); if (t) box.setAttribute("aria-label", t.textContent); }
  document.body.append(bg);
  trapOpen(box);
  return close;
}
// Смена экрана: листы и «Тема» прежнего экрана не остаются поверх нового
function closeOverlays() {
  document.querySelectorAll(".sheet-bg").forEach((bg) => (bg.close ? bg.close(true) : bg.remove()));
  closeLook();
}
// Выбор снизу: [{label, value, cls}] → значение или null (и когда лист закрыт сменой экрана)
function sheet(title, options) {
  return new Promise((done) => {
    let close = null;
    const box = h("div", { class: "sheet" }, h("h3", {}, title),
      options.map((o) => h("button", { class: o.cls || "", onclick: () => { done(o.value); close(); } }, o.label)),
      h("button", { class: "muted", onclick: () => close() }, "Отмена"));
    close = sheetOpen(box, () => done(null));
  });
}
// Кнопка на время действия гаснет; ошибка — всплывающим окном
async function busy(btn, fn) {
  if (btn) btn.disabled = true;
  try { return await fn(); } catch (e) { fail(e); } finally { if (btn) btn.disabled = false; }
}
async function copy(text) {
  try { await navigator.clipboard.writeText(text); } catch (_) {
    const ta = h("textarea", {}, text);
    document.body.append(ta); ta.select(); document.execCommand("copy"); ta.remove();
  }
  haptic(); toast("Скопировано");
}

// ── Роутер: #/путь, «Назад» — кнопка Telegram ──────────────
// На ПК карточка клиента и её экраны (QR, срок, лимит…) открываются панелью
// справа поверх списка клиентов; на телефоне и в Mini App — отдельным экраном.
const routes = [];
let token = 0;
const route = (re, fn) => { routes.push([re, fn]); return re; };
// Тот же адрес события hashchange не даёт — экран просто обновляется
const go = (path) => { if (curPath() === path) render(); else location.hash = path; };
const replace = (path) => { location.replace("#" + path); };
const back = () => (history.length > 1 ? history.back() : go("/"));
const CLIENT_SUB = /^\/client\//;

function openDrawer(path) {
  const sub = /^\/client\/[^/]+\/./.test(path), name = decodeURIComponent((path.match(/^\/client\/([^/]+)/) || [])[1] || "");
  drawerEl.replaceChildren(
    h("header", {}, sub ? h("button", { class: "ibtn", "aria-label": "Назад", title: "Назад", onclick: back }, icon("arrow-left")) : null,
      h("div", {}, h("div", { class: "eyebrow", style: "margin:0" }, "клиент"), h("h2", {}, name)),
      h("div", { class: "grow" }),
      h("button", { class: "ibtn", "aria-label": "Закрыть", title: "Закрыть (Esc)", onclick: () => go("/clients") }, icon("x"))),
    h("div", { class: "body" }));
  drawerEl.classList.add("on");
  syncScrim();
  trapOpen(drawerEl);
  // Строка клиента в таблице — подсвечена, пока открыта его карточка
  root.querySelectorAll("[data-name]").forEach((el) => el.classList.toggle("cur", el.dataset.name === name));
  return drawerEl.querySelector(".body");
}
function closeDrawer() {
  if (!drawerEl.classList.contains("on")) return;
  drawerEl.classList.remove("on");
  root.querySelectorAll(".cur").forEach((el) => el.classList.remove("cur"));
  syncScrim();
  trapClose(drawerEl);
}

// Две и больше карточки (.ecard) подряд — в одну сетку: на ПК в два столбца
// ровными рядами, на телефоне — столбиком, как раньше
function egrid(nodes) {
  const out = [];
  for (let i = 0; i < nodes.length; i++) {
    const isCard = (n) => n instanceof Element && n.classList.contains("ecard");
    if (!isCard(nodes[i]) || !isCard(nodes[i + 1])) { out.push(nodes[i]); continue; }
    const run = [];
    while (i < nodes.length && isCard(nodes[i])) run.push(nodes[i++]);
    i--;
    out.push(h("div", { class: "egrid" }, run));
  }
  return out;
}

// Снимки экранов: вернулся на экран — прежний вид сразу (без «Загрузка…»;
// данные подтянулись быстро — даже без приглушения), свежие его заменяют,
// как только придут. Каждый экран — вызов awg2 на сервере, это секунда-две.
const SNAP = new Map(), SNAP_MAX = 12;
function snapSave(path, target) {
  if (!path || target !== root || !target.childElementCount || [...target.children].some((c) => c.classList.contains("spin"))) return;
  SNAP.delete(path);
  SNAP.set(path, [...target.childNodes]);
  if (SNAP.size > SNAP_MAX) SNAP.delete(SNAP.keys().next().value);
}

async function show(path, target, my) {
  const live = () => my === token, inDrawer = target !== root;
  // Экран отрисовывает то, что успел загрузить; ушли с него — молчит.
  // Условные части экрана приходят как null — их просто нет (иначе «null» текстом)
  const ctx = { put: (...nodes) => {
    if (!live()) return;
    target.classList.remove("reloading");
    target.replaceChildren(...egrid(nodes.flat(Infinity).filter((n) => n != null && n !== false)));
  }, live, drawer: inDrawer };
  // Тот же экран обновляется после действия — прежнее остаётся на месте (без
  // «Загрузка…» и прыжка наверх), пока не придёт новое; нажать в нём нельзя
  const same = target.dataset.path === path && target.childElementCount > 0 && ![...target.children].some((c) => c.classList.contains("spin"));
  if (!same) snapSave(target.dataset.path, target);
  target.dataset.path = path;
  for (const [re, fn] of routes) {
    const m = path.match(re);
    if (!m) continue;
    const snap = !same && !inDrawer && SNAP.get(path);
    if (same) target.classList.add("reloading");
    else {
      if (inDrawer) target.scrollTop = 0;
      else { window.scrollTo(0, 0); S.listShown = false; S.listRedraw = null; }
      if (snap) { target.replaceChildren(...snap); target.classList.add("reloading"); }
      else ctx.put(h("div", { class: "spin" }, "Загрузка…"));
    }
    try {
      await fn(ctx, ...m.slice(1).map(decodeURIComponent));
      // Карточка поменяла клиента — список за ней показывает то же самое
      if (inDrawer && live() && S.listRedraw) S.listRedraw();
    } catch (e) {
      const tail = logTail(e, 12);
      ctx.put(h("div", { class: "card" }, h("div", { class: "bad" }, "❌ " + e.message),
        tail ? h("pre", {}, tail) : null,
        h("button", { class: "btn-block", onclick: render }, "Повторить")));
    } finally {
      if (live()) target.classList.remove("reloading");
    }
    return true;
  }
  return false;
}

// Шаг назад с поправкой: экран, на который вернулись, заменяется адресом
// fix(путь) (null — остаётся). После переименования и удаления клиента в
// истории не остаётся шагов на «Клиента bob нет» и двух списков подряд
let backFix = null;
function backWith(fix) {
  if (history.length < 2) return replace(fix(curPath()) || "/");
  const my = backFix = fix;
  history.back();
  // «Назад» не сработал (истории внутри панели нет) — просто заменить адрес
  setTimeout(() => { if (backFix === my) { backFix = null; const p = fix(curPath()); if (p) replace(p); } }, 1000);
}

let shownPath = null;
async function render() {
  const path = curPath();
  const my = ++token;
  if (badPath(path)) return replace("/clients");
  if (backFix) {
    const fix = backFix, to = fix(path);
    backFix = null;
    if (to && to !== path) return replace(to);
  }
  // Другой экран — листы и панели прежнего закрываются (выбор в них уже ни к чему)
  if (path !== shownPath) closeOverlays();
  shownPath = path;
  closePal(); closeMore();
  if (tg && tg.BackButton) tg.BackButton[path === "/" ? "hide" : "show"]();
  drawNav();
  const toDrawer = railOn() && CLIENT_SUB.test(path);
  if (!toDrawer) closeDrawer();
  if (toDrawer && !S.listShown) await show("/clients", root, my);
  if (my !== token) return;
  if (!await show(path, toDrawer ? openDrawer(path) : root, my)) replace("/");
}

// Строка вывода awg2 для узкого экрана: отступ меньше, колонки из пробелов сжаты
const tidy = (l) => {
  const lead = l.length - l.trimStart().length;
  return " ".repeat(Math.max(0, lead - 2)) + l.trim().replace(/ {3,}/g, "  ");
};

// ── Задача с живым журналом ────────────────────────────────
// Долгое (массовое создание, установка, сборка) идёт задачей awg2: журнал —
// по ходу, итог — на том же экране. done(data) рисует кнопки итога;
// opts.stdin — ввод задачи, opts.onBack(ok) — куда «Назад» (по умолчанию экран,
// с которого задачу запустили, уже с новым состоянием).
// Ушли с экрана — задача на сервере идёт дальше: опрос продолжается без
// отрисовки, итог — подсказкой.
async function runJob(ctx, title, args, done, opts = {}) {
  const started = Date.now(), name = plainTitle(title);
  const state = pill("идёт", "accent");
  const head = h("h1", {}, name, state), time = h("div", { class: "muted small mono" }), log = h("pre", {}, "запускаю…");
  const finish = (ok, text) => { state.className = "pill " + (ok ? "ok" : "bad"); state.textContent = text; };
  const foot = h("div");
  const backBtn = (ok) => h("button", { class: "btn-block", onclick: () => (opts.onBack || render)(ok) }, "◀️ Назад");
  ctx.put(head, time, log, foot);
  let id;
  try {
    id = (await post("/api/job", { args, stdin: opts.stdin })).data.id;
  } catch (e) {
    finish(false, "ошибка"); time.textContent = e.message;
    log.textContent = (e.log || "").trim() || "задача не запустилась";
    haptic("error"); foot.replaceChildren(backBtn(false));
    return;
  }
  let offset = 0, text = "", lostAt = 0;
  for (;;) {
    await new Promise((ok) => setTimeout(ok, 1500));
    let st;
    try {
      st = (await post("/api/job/status", { id, offset }, false, 75000)).data;
      lostAt = 0;
    } catch (e) {
      if (e.login) return;                 // сессия веб-панели кончилась — на экране уже вход
      // Бот мог перезапуститься по ходу задачи — задача awg2 от этого не встаёт
      lostAt = lostAt || Date.now();
      if (ctx.live()) time.textContent = `${e.message} — пробую снова…`;
      if (Date.now() - lostAt < (window.AWG_JOB_LOST_MS || 90000)) continue;
      if (!ctx.live()) { toast(`⚠️ ${name}: нет связи с сервером — итог не известен`, 6000); return; }
      // Связи нет давно: не бросаем ошибку в никуда, а говорим как есть
      finish(false, "нет связи");
      time.textContent = "Нет связи с сервером — задача могла продолжиться на сервере";
      haptic("error");
      await new Promise((ok) => foot.replaceChildren(
        h("button", { class: "btn-primary btn-block", onclick: ok }, "🔄 Повторить проверку"), backBtn(false)));
      state.className = "pill accent"; state.textContent = "идёт"; time.textContent = "проверяю…";
      foot.replaceChildren(); lostAt = 0;
      continue;
    }
    offset = st.offset || offset;
    if (st.log) text += st.log;
    const live = ctx.live();
    if (live && st.log) {
      // Рамки заголовков из терминального вывода awg2 здесь не нужны
      log.textContent = text.split("\n").filter((l) => !/^[\s━─═—–-]*$/.test(l)).map(tidy).slice(-300).join("\n") || "идёт…";
      log.scrollTop = log.scrollHeight;
    }
    if (live) time.textContent = fmtDur((Date.now() - started) / 1000);
    if (st.state === "running") continue;
    const ok = st.state === "done" && st.ok;
    if (!live) {
      haptic(ok ? "success" : "error");
      toast(ok ? `✅ ${name}: готово` : `❌ ${name}: ошибка — журнал: Диагностика → Журналы`, 6000);
      return;
    }
    finish(ok, ok ? "готово" : "ошибка");
    if (!ok) time.textContent = st.state === "lost" ? "Задача прервана: awg2 остановлен или сервер перезагружен" : (st.error || "ошибка");
    haptic(ok ? "success" : "error");
    foot.replaceChildren(...[].concat(ok && done ? done(st.data) : [], backBtn(ok)).flat(Infinity)
      .filter((n) => n != null && n !== false));
    return;
  }
}

// ── Общее для разделов ────────────────────────────────────
// Ответ awg2 api целиком: data и журнал
const callR = (args, { timeout = 120, stdin } = {}) => post("/api/call", { args, timeout, stdin });
// Итог по журналу awg2: строки «√», «→» и «▲», последние две-три
function outcome(log, fallback) {
  const lines = (log || "").split("\n").filter((l) => /^\s*[√→▲]/.test(l)).map((l) => l.replace(/^\s*[√→]\s*/, "").trim());
  return lines.slice(-3).join("\n") || fallback;
}
// Быстрое действие: итог — подсказкой, ошибка — окном с журналом, затем
// экран перерисовывается (then(r) — вместо перерисовки)
function quick(btn, title, args, then = render, timeout = 600) {
  return busy(btn, async () => {
    const r = await callR(args, { timeout });
    haptic(); toast("✅ " + outcome(r.log, title), 3500);
    then(r);
  });
}
async function quickAsk(btn, question, title, args, then) {
  if (await confirmTg(question)) await quick(btn, title, args, then);
}
async function jobAsk(ctx, question, title, args, done) {
  if (await confirmTg(question)) await runJob(ctx, title, args, done);
}
// Журнал awg2 «Ключ : значение» → строки карточки; ● — хорошо, ▲ — внимание
const tone = (s) => (/^[●√]/.test(s) ? "ok" : /^[▲×]/.test(s) ? "warn" : /^○/.test(s) ? "muted" : "");
function logCard(log, ...head) {
  const rows = [];
  for (const raw of (log || "").split("\n")) {
    const l = raw.trim();
    if (!l || /^[━─═—–-]+$/.test(l)) continue;
    const m = l.match(/^([^:]{2,22}?)\s*:\s+(.+)$/);
    // Длинное значение — под названием, а не узким столбцом справа
    rows.push(!m ? h("div", { class: "small " + tone(l) }, l.replace(/^→\s*/, ""))
      : m[2].length > 26 ? h("div", { style: "padding:5px 0" }, h("div", { class: "muted" }, m[1]), h("div", { class: tone(m[2]) }, m[2]))
        : kv(m[1], h("span", { class: tone(m[2]) }, m[2])));
  }
  return h("div", { class: "card" }, head, rows);
}
// Вывод awg2 без рамок заголовков — на телефоне они переносятся в мусор
const plainLog = (text) => (text || "").split("\n").filter((l) => !/^[\s━─═]+$/.test(l) || !l.trim()).map(tidy).join("\n").trim();
// Длинный вывод (диагностика) — снизу, поверх экрана; text === false — без вывода
function logSheet(title, text) {
  let close = null;
  const box = h("div", { class: "sheet" }, h("h3", {}, title), text === false ? null : h("pre", {}, plainLog(text) || "пусто"),
    h("button", { onclick: () => close() }, "Закрыть"));
  close = sheetOpen(box);
}
// Переключатель строкой: onToggle(новое) — промис; ошибка оставляет как было
function switchRow(title, sub, on, onToggle) {
  const sw = h("div", { class: "switch" + (on ? " on" : "") });
  return h("div", { class: "card item", onclick: () => busy(null, async () => {
    const next = !sw.classList.contains("on");
    await onToggle(next);
    sw.classList.toggle("on", next);
    haptic();
  }) }, h("div", { class: "main" }, h("div", { class: "title wrap" }, title), sub ? h("div", { class: "sub wrap" }, sub) : null), sw);
}
// Файл с телефона в поле ввода (конфиги, профили)
function fileField(ta) {
  const input = h("input", { type: "file", accept: ".conf,.txt,text/plain", style: "display:none", onchange: async () => {
    const f = input.files[0];
    if (!f) return;
    if (f.size > 64 * 1024) return fail(new Error("Файл больше 64 КБ — это не конфиг"));
    ta.value = await f.text();
    toast("Загружен " + f.name);
  } });
  return [input, h("button", { class: "btn-block", style: "margin-top:0", onclick: () => input.click() }, "📎 Выбрать файл"),
    h("label", {}, "или вставь текст")];
}
// Кнопка «Скопировать» — с иконкой копирования, а не списка
const copyBtn = (label, text, cls = "btn-block") => h("button", { class: cls, onclick: () => copy(text) }, icon("copy"), label);
const btn = (label, onclick, cls) => h("button", { class: cls || null, onclick: (ev) => onclick(ev.currentTarget) }, label);
const hint = (text) => h("div", { class: "muted small", style: "margin:8px 4px" }, text);
// IPv4 и домен — как valid_ip и valid_domain в awg2: октет до 255 без ведущих
// нулей; метки домена не начинаются и не кончаются дефисом, одни цифры — не домен
const IP_RE = /^(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$/;
const validIp = (v) => { const m = IP_RE.exec(v); return !!m && m.slice(1).every((o) => +o <= 255); };
const DOMAIN_RE = /^(?=.{1,253}$)(?![\d.]+$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;
// Enter в поле — как нажатие кнопки формы (в многострочном — Ctrl+Enter)
function enterTo(button, ...fields) {
  fields.forEach((f) => f.addEventListener("keydown", (ev) => {
    if (ev.key !== "Enter" || ev.isComposing || (f.tagName === "TEXTAREA" && !(ev.ctrlKey || ev.metaKey))) return;
    ev.preventDefault();
    if (!button.disabled) button.click();
  }));
  return button;
}
const validPort = (v, min = 1) => /^\d{1,5}$/.test(v) && +v >= min && +v <= 65535;

// Строка меню раздела: иконка (из эмодзи в подписи), заголовок, пояснение, «›»
function menuItem(label, sub, onclick) {
  const m = EMOJI_RE.exec(label);
  const name = m && EMOJI_ICON[m[1]];
  return h("div", { class: "item", onclick }, name ? h("div", { class: "ibox" }, icon(name)) : null,
    h("div", { class: "main" }, h("div", { class: "title" }, name ? label.slice(m[0].length) : label),
      sub ? h("div", { class: "sub wrap" }, sub) : null),
    h("div", { class: "side" }, icon("chevron-right")));
}

// ── Обзор ─────────────────────────────────────────────────
// Выходы трафика и путь каждого клиента: напрямую, WARP, Xray (свой выход у
// клиента), tun2socks, exit-ноды. Цвет выхода — один на схеме, в таблице и списках.
const OUT_COLORS = ["var(--violet)", "var(--amber)", "var(--blue)", "var(--cyan)", "var(--red)", "var(--ok)"];
function exitsModel(rows, r) {
  r = r || {};
  const ex = [{ id: "direct", name: "Напрямую", short: "Direct", c: "var(--muted)" }];
  const add = (id, name, short, c, grp) => {
    if (!ex.some((e) => e.id === id)) ex.push({ id, name, short, grp: grp || short, c: c || OUT_COLORS[(ex.length - 1) % OUT_COLORS.length] });
    return id;
  };
  const kind = r.kind || "";
  const pick = (c) => {
    if (kind === "warp") return c.warp !== false ? add("warp", "WARP", "WARP", "var(--cyan)") : "direct";
    if (kind === "tun2socks") return add("t2s", "tun2socks", "tun2socks", "var(--blue)");
    if (kind === "xray") {
      if (c.xray === false) return "direct";
      const out = c.xray_out || (r.main && r.main !== "balancer" ? r.main : "");
      return add("x:" + (out || "main"), out ? "Xray · " + out : r.main === "balancer" ? "Xray · балансировщик" : "Xray", out || "Xray", null, "Xray");
    }
    if (kind === "exits") {
      const v = c.exit_choice || "shared";
      if (v === "off") return "direct";
      return v === "shared" ? add("shared", "Exit-ноды WG · общий", "Exit WG", null, "Exit WG") : add("n:" + v, "Exit WG · " + v, v, null, "Exit WG");
    }
    return "direct";
  };
  const of = {};
  for (const c of rows) of[c.name] = pick(c);
  // Выходы, на которые сейчас никто не идёт, — тоже на схеме
  if (kind === "xray" && r.per_client) (r.tags || []).forEach((t) => add("x:" + t, "Xray · " + t, t, null, "Xray"));
  if (kind === "exits" && r.mode === "peers") (r.nodes || []).forEach((n) => add("n:" + n, "Exit WG · " + n, n, null, "Exit WG"));
  // Теги выходов Xray бывают длинными (proxy_страна_сервер_…) — коротко, 5 символов
  const xs = ex.filter((e) => e.id.startsWith("x:") && e.id !== "x:main"), sh = xrayShort(xs.map((e) => e.short));
  xs.forEach((e) => { e.short = sh[e.short]; });
  return { ex, of, get: (id) => ex.find((e) => e.id === id) || ex[0] };
}
// Короткие имена выходов Xray: без общего начала всех тегов и слова proxy/out —
// первые 5 символов; совпали у двух выходов — по символу больше, пока не различатся
function xrayShort(tags) {
  let pre = "";
  if (tags.length > 1) {
    pre = tags.reduce((p, t) => { while (!t.startsWith(p)) p = p.slice(0, -1); return p; });
    pre = pre.slice(0, pre.search(/[_\-.\s][^_\-.\s]*$/) + 1);
  }
  let base = tags.map((t) => t.slice(pre.length).replace(/^(proxy|outbound|out|xray)(?=[_\-.\s]|$)/i, "")
    .replace(/^[_\-.\s]+/, "") || t);
  // Остались огрызки вроде «1» и «2» (out-1, out-2) — лучше теги как есть
  if (base.some((b) => b.length < 2)) base = tags;
  const cut = (b, n) => b.slice(0, n).replace(/[_\-.\s]+$/, "") || b.slice(0, n);
  const res = {};
  tags.forEach((t, i) => {
    let n = 5;
    while (n < base[i].length && base.some((b, j) => j !== i && cut(b, n) === cut(base[i], n))) n++;
    res[t] = cut(base[i], n);
  });
  return res;
}
// Подпись выхода: длинный тег Xray — «Xray · коротко», полное имя — подсказкой
const exitLabel = (e, max = 24) => (e.name.length <= max ? e.name
  : e.grp === "Xray" && e.id !== "x:main" ? "Xray · " + e.short : e.name.slice(0, max - 1) + "…");
const routeChip = (c, mdl) => { const e = mdl.get(mdl.of[c.name]); return h("span", { class: "rt", title: e.name }, h("i", { style: `background:${e.c}` }), e.short); };

// Скорость: байт/с → «12.4 Мбит/с»
function fmtRate(bps) {
  const bit = (bps || 0) * 8;
  if (bit >= 1e9) return [(bit / 1e9).toFixed(2), "Гбит/с"];
  if (bit >= 1e6) return [(bit / 1e6).toFixed(bit >= 1e8 ? 0 : 1), "Мбит/с"];
  return [(bit / 1e3).toFixed(bit >= 1e5 ? 0 : 1), "Кбит/с"];
}
const rateText = (bps) => fmtRate(bps).join(" ");

// Маршруты трафика: полоса — доля выходов в трафике за сегодня, под ней выходы
// списком — имя целиком, сколько клиентов и сколько в сети, сегодня, клиенты чипами
function routesView(rows, mdl) {
  const by = {};
  for (const c of rows) {
    const id = mdl.of[c.name], x = by[id] || (by[id] = { e: mdl.get(id), clients: [], today: 0 });
    x.clients.push(c); x.today += c.today || 0;
  }
  // Выход, куда сейчас никто не идёт (свободный выход Xray, нода), — в конце списка
  const list = mdl.ex.map((e) => by[e.id] || { e, clients: [], today: 0 })
    .filter((x) => x.clients.length || x.e.id !== "direct")
    .sort((a, b) => (b.today - a.today) || (b.clients.length - a.clients.length));
  const total = list.reduce((a, x) => a + x.today, 0);
  // Сегодня трафика ещё не было — доли по числу клиентов
  const share = (x) => (total ? x.today / total : x.clients.length / Math.max(1, rows.length));
  const pct = (x) => Math.round(share(x) * 100);
  const bar = h("div", { class: "rbar", role: "img",
    "aria-label": list.filter((x) => share(x) > 0).map((x) => `${x.e.name} ${pct(x)}%`).join(", ") },
  list.filter((x) => share(x) > 0).map((x) => h("i", { style: `flex:${share(x).toFixed(4)};background:${x.e.c}`, title: `${x.e.name} · ${pct(x)}%` })));
  const MAXCHIPS = 8;
  // Клиенты выхода чипами; «ещё N» раскрывает всех — в области с прокруткой,
  // блок не растёт (запоминается, пока открыт обзор)
  const open = S.chipsOpen || (S.chipsOpen = {});
  const chips = (id, clients) => {
    const rc = h("div", { class: "rc" });
    const fill = () => {
      const all = !!open[id], n = clients.length;
      rc.classList.toggle("open", all);
      rc.replaceChildren(...(all ? clients : clients.slice(0, MAXCHIPS)).map((c) => h("a", {
        class: "cchip" + (c.blocked ? " bad" : c.online ? " on" : ""), title: c.blocked ? blockedWord(c) : seen(c),
        onclick: (ev) => { ev.stopPropagation(); go("/client/" + encodeURIComponent(c.name)); } }, c.name)),
      n > MAXCHIPS ? h("a", { class: "xmore", role: "button",
        onclick: (ev) => { ev.stopPropagation(); open[id] = !all; fill(); } }, all ? "свернуть" : `ещё ${n - MAXCHIPS}`) : null);
    };
    fill();
    return rc;
  };
  return [
    bar,
    h("div", { class: "rcap" }, total ? `сегодня ${fmtBytes(total)}` : "сегодня трафика ещё не было — доля по числу клиентов"),
    h("div", { class: "rlist" }, list.map((x) => {
      const on = x.clients.filter((c) => c.online).length, n = x.clients.length;
      const clients = sortRows(x.clients, "activity");
      return h("div", { class: "rx", onclick: () => go("/tunnels") },
        h("i", { class: "sw", style: `background:${x.e.c}` }),
        h("div", { class: "rm" }, h("b", { title: x.e.name }, exitLabel(x.e)),
          h("span", {}, n ? `${n} ${plural(n, "клиент", "клиента", "клиентов")}` + (on ? ` · ${on} в сети` : " · никого в сети") : "никто не идёт"),
          n ? chips(x.e.id, clients) : null),
        h("div", { class: "rv" }, fmtBytes(x.today), h("small", {}, share(x) ? pct(x) + "%" : "—")));
    })),
  ];
}

// Клиенты WG + обфускатора в виде «список»: одна строка — все идут напрямую,
// клиенты чипами (нажатие — карточка клиента обфускатора)
function wgobfRoutes(wrows) {
  const on = wrows.filter((c) => c.online).length, n = wrows.length;
  const total = wrows.reduce((a, c) => a + (c.today || 0), 0);
  return h("div", { class: "rlist" }, h("div", { class: "rx", onclick: () => go("/wgobf") },
    h("i", { class: "sw", style: "background:var(--muted)" }),
    h("div", { class: "rm" }, h("b", {}, "wgobf0 → напрямую"),
      h("span", {}, `${n} ${plural(n, "клиент", "клиента", "клиентов")}` + (on ? ` · ${on} в сети` : " · никого в сети")),
      h("div", { class: "rc" }, sortRows(wrows, "activity").map((c) => h("a", { class: "cchip" + (c.online ? " on" : ""), title: c.sub,
        onclick: (ev) => { ev.stopPropagation(); go("/wgobf/client/" + encodeURIComponent(c.name)); } }, c.name)))),
    h("div", { class: "rv" }, fmtBytes(total), h("small", {}, "с запуска"))));
}

// Схема: клиенты → сервер → выходы. Клиентов много — показаны самые активные.
// opt — та же схема для WG + обфускатора: свой узел (hub), куда ведут нажатия
// (hubPath, cpath, exitPath), подпись трафика выхода (esub), ключ прокрутки (key)
function topology(el, rows, mdl, srvLabel, opt) {
  opt = opt || {};
  const hub = opt.hub || "awg0", stKey = "topoSt" + (opt.key || "");
  const cpath = opt.cpath || ((n) => "/client/" + encodeURIComponent(n));
  const esub = opt.esub || ((v) => `${fmtBytes(v)} сегодня`);
  const W = Math.max(300, el.clientWidth || 600), narrow = W < 560, MAXC = 6;
  const shown = sortRows(rows, "activity").sort((a, b) => (b.online - a.online) || ((b.today || 0) - (a.today || 0)));
  // Клиентов больше, чем влезает, — схема той же высоты, а столбец клиентов
  // листается внутри неё (колесо, тачпад, палец); awg0 и выходы стоят на месте
  const scroll = shown.length > MAXC;
  const cname = (c) => (c.name.length > 16 ? c.name.slice(0, 15) + "…" : c.name);
  const exits = mdl.ex.filter((e) => e.id !== "direct" || shown.some((c) => mdl.of[c.name] === "direct") || mdl.ex.length === 1);
  const row = narrow ? 44 : 46, Hc = Math.max(scroll ? MAXC : shown.length, exits.length, 2) * row + 24;
  const cap = scroll ? 22 : 0, Hh = Hc + cap;
  const exLabel = (e) => (narrow ? (e.short.length > 10 ? e.short.slice(0, 9) + "…" : e.short) : exitLabel(e));
  // На телефоне поля под подписи — по самой длинной подписи, остальное — линиям
  let cx = 190, exX = W - 200;
  if (narrow) {
    const tw = topology.tw || (topology.tw = document.createElement("canvas").getContext("2d"));
    tw.font = `600 12px ${(getComputedStyle(document.documentElement).getPropertyValue("--sans") || "system-ui").trim()}`;
    const widest = (list) => Math.max(0, ...list.map((t) => tw.measureText(t).width));
    cx = Math.round(Math.min(130, Math.max(64, widest(shown.map((c) => cname(c))) + 26)));
    exX = Math.round(W - Math.min(116, Math.max(54, widest(exits.map(exLabel)) + 28)));
  }
  const sx = narrow ? Math.round((cx + 9 + exX - 11) / 2) : W / 2, sy = Hc / 2;
  const spread = (i, k) => 12 + row / 2 + i * (Hc - 24 - row) / ((k - 1) || 1) + (k === 1 ? (Hc - 24 - row) / 2 : 0);
  const cy = (i) => (scroll ? 12 + row / 2 + i * row : spread(i, shown.length)), ey = (i) => spread(i, exits.length);
  const sw = narrow ? 66 : 124, sh = narrow ? 72 : 96;
  const bez = (x1, y1, x2, y2) => { const m = (x1 + x2) / 2; return `M${x1},${y1} C${m},${y1} ${m},${y2} ${x2},${y2}`; };
  const esc = (t) => String(t).replace(/[&<>"]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[ch]));
  const sum = {}, maxT = Math.max(1, ...rows.map((c) => c.today || 0));
  rows.forEach((c) => { const e = mdl.of[c.name]; sum[e] = (sum[e] || 0) + (c.today || 0); });
  const maxE = Math.max(1, ...Object.values(sum));
  const csub = (c) => c.sub || (c.blocked ? blockedWord(c) : c.online ? `${fmtBytes(c.today || 0)} сегодня` : c.handshake ? `${fmtDur(c.ago)} назад` : "не подключался");
  const ctitle = (c) => `${c.name} → ${mdl.get(mdl.of[c.name]).name}`;
  // Линии клиент → awg0 (у листаемого столбца — только видимых клиентов)
  const links = (y0) => {
    let p = "";
    shown.forEach((c, i) => {
      const y = cy(i) - y0;
      if (y < 6 || y > Hc - 6) return;
      const e = mdl.get(mdl.of[c.name]), d = bez(cx + 9, y, sx - sw / 2, sy), t = (c.today || 0) / maxT;
      p += `<path class="link ${c.online ? "" : "off"}" data-c="${esc(c.name)}" data-e="${esc(e.id)}" d="${d}" stroke="${c.blocked ? "var(--red)" : e.c}"/>`;
      if (c.online) p += `<path class="flow" data-c="${esc(c.name)}" data-e="${esc(e.id)}" d="${d}" stroke="${e.c}" style="animation-duration:${(7 - t * 4.5).toFixed(1)}s"/>`;
    });
    return p;
  };
  // Толщина линии к выходу — трафик за сегодня; бегущие точки — только пока через
  // выход идёт кто-то в сети (никого нет — линия стоит)
  const used = new Set(rows.filter((c) => c.online && !c.blocked).map((c) => mdl.of[c.name]));
  let s = "";
  exits.forEach((e, j) => {
    const d = bez(sx + sw / 2, sy, exX - 11, ey(j)), t = (sum[e.id] || 0) / maxE;
    s += `<path class="link${used.has(e.id) ? "" : " idle"}" data-e="${esc(e.id)}" d="${d}" stroke="${e.c}" style="stroke-width:${(1.4 + t * 2.4).toFixed(1)}"/>`;
    if (used.has(e.id)) s += `<path class="flow" data-e="${esc(e.id)}" d="${d}" stroke="${e.c}" style="animation-duration:${(5.5 - t * 3.5).toFixed(1)}s"/>`;
  });
  if (!scroll) {
    s += links(0);
    shown.forEach((c, i) => {
      const col = c.blocked ? "var(--red)" : c.online ? "var(--ok)" : "var(--dim)";
      s += `<g class="node" data-c="${esc(c.name)}" data-e="${esc(mdl.of[c.name])}"><title>${esc(ctitle(c))}</title>
        <circle cx="${cx}" cy="${cy(i)}" r="${c.online ? 6 : 5}" fill="${col}"/>
        ${c.online ? `<circle cx="${cx}" cy="${cy(i)}" r="10" fill="none" stroke="${col}" stroke-opacity=".3"/>` : ""}
        <text class="lbl" x="${cx - 16}" y="${cy(i) + (narrow ? 4 : 0)}" text-anchor="end">${esc(cname(c))}</text>
        ${narrow ? "" : `<text class="lbl2" x="${cx - 16}" y="${cy(i) + 14}" text-anchor="end">${esc(csub(c))}</text>`}</g>`;
    });
  } else {
    s += `<g class="cl"></g><text class="lbl2" x="${cx - 16}" y="${Hh - 6}" text-anchor="end">↕ ${shown.length} ${plural(shown.length, "клиент", "клиента", "клиентов")}</text>`;
  }
  s += `<g class="node" data-srv="1"><rect x="${sx - sw / 2}" y="${sy - sh / 2}" width="${sw}" height="${sh}" rx="16" fill="var(--panel2)" stroke="var(--acc)" stroke-width="1.5"/>
    <image class="tz" x="${sx - 18}" y="${sy - sh / 2 + 8}" width="36" height="36" href="${tzIcon()}"/>
    <text class="lbl" x="${sx}" y="${sy + (narrow ? 26 : 18)}" text-anchor="middle">${esc(hub)}</text>
    ${narrow ? "" : `<text class="lbl2" x="${sx}" y="${sy + 34}" text-anchor="middle">${esc(srvLabel)}</text>`}</g>`;
  exits.forEach((e, j) => {
    s += `<g class="node" data-e="${esc(e.id)}"><title>${esc(e.name)}</title><rect x="${exX - 11}" y="${ey(j) - 11}" width="22" height="22" rx="7" fill="${e.c}"/>
      <text class="lbl" x="${exX + 20}" y="${ey(j) + (narrow ? 4 : 0)}">${esc(exLabel(e))}</text>
      ${narrow ? "" : `<text class="lbl2" x="${exX + 20}" y="${ey(j) + 14}">${esc(esub(sum[e.id] || 0))}</text>`}</g>`;
  });
  el.innerHTML = `<svg viewBox="0 0 ${W} ${Hh}" height="${Hh}" role="img" aria-label="Маршруты трафика: клиенты, ${esc(hub)}, выходы">${s}</svg>`;
  if (scroll) {
    // Столбец клиентов — обычная прокрутка браузера; линии перерисовываются по ней
    const prev = S[stKey] || 0;
    const inner = h("div", { class: "tci", style: `height:${shown.length * row + 24}px` }, shown.map((c, i) => h("div", {
      class: "node tc", "data-c": c.name, "data-e": mdl.of[c.name], title: ctitle(c), style: `top:${cy(i) - row / 2}px;height:${row}px` },
    h("span", { class: "tn" }, h("b", {}, cname(c)), narrow ? null : h("small", {}, csub(c))),
    h("i", { class: "dot" + (c.blocked ? " bad" : c.online ? " on" : "") }))));
    const col = h("div", { class: "tcl", style: `width:${cx + 14}px;height:${Hc}px` }, inner);
    el.append(col);
    const g = el.querySelector("g.cl");
    let raf = 0;
    const redraw = () => { raf = 0; S[stKey] = col.scrollTop; g.innerHTML = links(col.scrollTop); };
    col.addEventListener("scroll", () => { if (!raf) raf = requestAnimationFrame(redraw); }, { passive: true });
    col.scrollTop = prev;
    redraw();
  }
  // Наведение — путь клиента или выхода; нажатие — карточка клиента или туннели
  el.querySelectorAll(".node").forEach((g) => {
    g.addEventListener("mouseenter", () => {
      if (g.dataset.srv) return;
      const c = g.dataset.c, e = g.dataset.e;
      el.classList.add("dimmed");
      el.querySelectorAll("[data-e]").forEach((p) => {
        p.classList.toggle("hl", c ? p.dataset.c === c || (!p.dataset.c && p.dataset.e === e) : p.dataset.e === e);
      });
    });
    g.addEventListener("mouseleave", () => { el.classList.remove("dimmed"); el.querySelectorAll(".hl").forEach((p) => p.classList.remove("hl")); });
    g.addEventListener("click", () => go(g.dataset.srv ? opt.hubPath || "/server" : g.dataset.c ? cpath(g.dataset.c)
      : opt.exitPath || "/tunnels"));
  });
}

// Окна, которые листаются пальцем и вкладками (tabs — кнопки окон). Лента едет
// transform'ом, без scroll-snap — работает и в старом Edge. Неактивное окно
// сжато по высоте: короткое окно не тянет за собой высоту длинного; на время
// сдвига соседнее — не выше текущего. onGo(i) — окно сменилось
function swiper(slides, tabs, i0, onGo) {
  const track = h("div", { class: "ptrack" }, slides), el = h("div", { class: "pager" }, track);
  let cur = Math.max(0, Math.min(slides.length - 1, i0)), tmr = 0, x0 = null, y0 = 0, dx = 0, horiz = null, swiped = 0;
  const open = () => {
    const hh = slides[cur].offsetHeight;
    slides.forEach((s, k) => { if (k !== cur) { s.style.maxHeight = hh + "px"; s.classList.remove("off"); s.classList.add("peek"); } });
  };
  const settle = () => slides.forEach((s, k) => {
    s.classList.remove("peek"); s.style.maxHeight = ""; s.classList.toggle("off", k !== cur); s.setAttribute("aria-hidden", String(k !== cur));
  });
  const show = (i, anim) => {
    i = Math.max(0, Math.min(slides.length - 1, i));
    const was = cur;
    clearTimeout(tmr);
    if (anim) open();
    cur = i;
    track.style.transition = anim ? "" : "none";
    track.style.transform = `translateX(${-100 * cur}%)`;
    tabs.forEach((b, k) => { b.classList.toggle("on", k === cur); b.setAttribute("aria-pressed", String(k === cur)); });
    if (anim) tmr = setTimeout(settle, 320); else settle();
    if (i !== was) onGo(i);
  };
  tabs.forEach((b, k) => b.addEventListener("click", () => show(k, true)));
  // Палец: в сторону — листает, вверх-вниз — прокрутка страницы как обычно
  const start = (x, y) => { x0 = x; y0 = y; dx = 0; horiz = null; };
  const move = (x, y, ev) => {
    if (x0 == null) return;
    if (horiz == null) {
      if (Math.abs(x - x0) < 8 && Math.abs(y - y0) < 8) return;
      horiz = Math.abs(x - x0) > Math.abs(y - y0);
      if (horiz) { clearTimeout(tmr); open(); track.style.transition = "none"; }
    }
    if (!horiz) return;
    if (ev.cancelable) ev.preventDefault();
    dx = x - x0;
    // За крайним окном лента тянется туго
    const edge = (cur === 0 && dx > 0) || (cur === slides.length - 1 && dx < 0);
    track.style.transform = `translateX(${-cur * track.clientWidth + (edge ? dx / 3 : dx)}px)`;
  };
  const end = () => {
    if (x0 == null) return;
    x0 = null;
    if (!horiz) return;
    swiped = Date.now();
    const need = Math.min(60, track.clientWidth / 5);
    show(cur + (dx < -need ? 1 : dx > need ? -1 : 0), true);
  };
  el.addEventListener("touchstart", (ev) => { if (ev.touches.length === 1) start(ev.touches[0].clientX, ev.touches[0].clientY); else x0 = null; },
    { passive: true });
  el.addEventListener("touchmove", (ev) => { if (ev.touches.length === 1) move(ev.touches[0].clientX, ev.touches[0].clientY, ev); }, { passive: false });
  el.addEventListener("touchend", end);
  el.addEventListener("touchcancel", end);
  if (!("ontouchstart" in window) && window.PointerEvent) {
    // Сенсорный экран без touch-событий (Edge): те же жесты указателем, мышь — вкладками
    el.addEventListener("pointerdown", (ev) => { if (ev.pointerType !== "mouse" && ev.isPrimary) start(ev.clientX, ev.clientY); });
    el.addEventListener("pointermove", (ev) => { if (ev.pointerType !== "mouse" && ev.isPrimary) move(ev.clientX, ev.clientY, ev); });
    el.addEventListener("pointerup", end);
    el.addEventListener("pointercancel", end);
  }
  // Пролистнул — отпущенный палец не нажимает узел схемы под ним
  el.addEventListener("click", (ev) => { if (Date.now() - swiped < 400) { ev.stopPropagation(); ev.preventDefault(); } }, true);
  show(cur, false);
  return el;
}

// Живая скорость — по счётчикам awg0 раз в 3 секунды, пока открыт обзор
function liveSvg(L) {
  const W = 300, Hh = 120, n = Math.max(L.rx.length, 2);
  const max = Math.max(1, ...L.rx, ...L.tx) * 1.15;
  const pts = (a) => a.map((v, i) => `${((i + n - a.length) * W / (n - 1)).toFixed(1)},${(Hh - v * Hh / max).toFixed(1)}`).join(" ");
  const el = svg("svg", { viewBox: `0 0 ${W} ${Hh}`, preserveAspectRatio: "none", "aria-hidden": "true" });
  el.innerHTML = `<defs><linearGradient id="lg" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="var(--cyan)" stop-opacity=".35"/>
      <stop offset="1" stop-color="var(--cyan)" stop-opacity="0"/></linearGradient></defs>
    ${[0.25, 0.5, 0.75].map((f) => `<line x1="0" x2="${W}" y1="${Hh * f}" y2="${Hh * f}" stroke="var(--line)" vector-effect="non-scaling-stroke"/>`).join("")}
    ${L.rx.length > 1 ? `<polygon points="${((n - L.rx.length) * W / (n - 1)).toFixed(1)},${Hh} ${pts(L.rx)} ${W},${Hh}" fill="url(#lg)"/>
    <polyline points="${pts(L.rx)}" fill="none" stroke="var(--cyan)" stroke-width="2" vector-effect="non-scaling-stroke"/>
    <polyline points="${pts(L.tx)}" fill="none" stroke="var(--acc)" stroke-width="2" vector-effect="non-scaling-stroke"/>` : ""}`;
  return el;
}
// «В сети» по живым счётчикам: от клиента за 45 с пришёл хоть пакет — keepalive
// шлёт их раз в 22-30 с. Рукопожатие в сводке держит отключившегося «в сети»
// ещё до 3 минут. Пока замеров меньше 45 с или они перестали приходить —
// верим сводке
const LIVE_IDLE = 45000;
function liveOnline(c, L) {
  const now = Date.now();
  if (!L || !L.since || !L.act || c.blocked || now - L.at > 10000) return c.online;
  const t = L.act[c.name];
  if (t && now - t < LIVE_IDLE) return true;
  return now - L.since < LIVE_IDLE ? c.online : false;
}

async function liveLoop(ctx, onTick) {
  const L = S.live || (S.live = { rx: [], tx: [], prev: null, per: {}, at: 0, act: {}, since: 0 });
  // Давние замеры не годятся: скорость и «в сети» считаются с нуля
  if (Date.now() - L.at > 30000) { L.prev = null; L.rx = []; L.tx = []; L.per = {}; L.act = {}; L.since = 0; }
  while (ctx.live()) {
    if (!document.hidden) {
      try {
        // Вкладка была скрыта: первый замер охватил бы весь провал — скорость и «в сети» считаются с нуля
        if (L.at && Date.now() - L.at > 10000) { L.prev = null; L.rx = []; L.tx = []; L.per = {}; L.act = {}; L.since = 0; }
        const d = (await post("/api/call", { args: ["traffic", "now"] }, true, 8000)).data;
        if (d && d.peers) {
          if (L.prev && d.ts > L.prev.ts) {
            const dt = d.ts - L.prev.ts, per = {};
            let rx = 0, tx = 0;
            for (const [n, [r, t]] of Object.entries(d.peers)) {
              const p = L.prev.peers[n];
              if (!p) continue;
              // Счётчик сбросился (рестарт awg0) — этот замер без прироста
              const a = Math.max(0, r - p[0]) / dt, b = Math.max(0, t - p[1]) / dt;
              per[n] = [a, b]; rx += a; tx += b;
              if (r > p[0]) L.act[n] = Date.now();             // от клиента пришёл пакет
            }
            // Клиенты WG + обфускатора (wgobf0) — в общую скорость сервера
            const wp = L.prev.wpeers || {};
            for (const [n, [r, t]] of Object.entries(d.wpeers || {})) {
              const p = wp[n];
              if (p) { rx += Math.max(0, r - p[0]) / dt; tx += Math.max(0, t - p[1]) / dt; }
            }
            L.rx.push(rx); L.tx.push(tx);
            if (L.rx.length > 60) { L.rx.shift(); L.tx.shift(); }
            L.per = per;
          }
          L.prev = d; L.at = Date.now(); L.since = L.since || L.at;
        }
      } catch (_) { /* сервер не ответил — следующий замер */ }
      // И без ответа: давний замер обзор показывает как «нет связи», а не застывшую скорость
      if (ctx.live()) onTick(L);
    }
    await new Promise((ok) => setTimeout(ok, 3000));
  }
}

// Журнал сроков и лимитов (/var/log/awg2-expire.log) → события
const EV_KIND = {
  limit: ["shield-off", "var(--red)", (n, x) => [`${n} заблокирован: лимит исчерпан`, x]],
  limit90: ["gauge", "var(--amber)", (n, x) => [`${n} израсходовал 90% лимита`, x]],
  unlimit: ["circle-check", "var(--ok)", (n, x) => [`${n} разблокирован`, x]],
  expired: ["hourglass", "var(--red)", (n, x) => [`${n}: срок истёк`, x]],
  warn1h: ["clock", "var(--amber)", (n, x) => [`${n}: срок истекает через час`, x]],
  watchdog: ["refresh-cw", "var(--blue)", (n, x) => ["Таймер сроков и лимитов перезапущен", [n, x].filter(Boolean).join(" ")]],
};
function parseEvents(log) {
  const out = [];
  for (const line of (log || "").split("\n")) {
    const m = /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):\d\d (\w+): ?([^(]*?)\s*(?:\((.*)\))?\s*$/.exec(line.trim());
    if (!m || !EV_KIND[m[6]]) continue;
    const [ic, col, fn] = EV_KIND[m[6]];
    const [t, x] = fn(m[7].trim(), (m[8] || "").trim());
    out.push({ date: `${m[3]}.${m[2]}`, time: `${m[4]}:${m[5]}`, day: `${m[1]}-${m[2]}-${m[3]}`, ic, col, t, x, name: m[7].trim() });
  }
  return out.reverse();
}
const todayIso = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };
const evRow = (e) => h("div", { class: "ev", style: e.name && !/\s/.test(e.name) ? "cursor:pointer" : null,
  onclick: e.name && !/\s/.test(e.name) && byName(e.name) ? () => go("/client/" + encodeURIComponent(e.name)) : null },
h("time", {}, e.day === todayIso() ? e.time : e.date), h("span", { class: "ic", style: `color:${e.col};background:color-mix(in srgb, ${e.col} 14%, transparent)` }, icon(e.ic)),
h("div", { class: "t" }, e.t, e.x ? h("span", { class: "x" }, e.x) : null));

// Предупреждения сервера — те же, что были на главной
function homeAlerts(d) {
  const s = d.server || {}, c = d.components || {};
  return [
    s.exists && !s.up ? ["awg0 не поднят — Сервер → Починить", "/server"] : null,
    c.installed && c.reboot ? [c.reboot, "/server/module"] : null,
    c.kernel_gap ? [`Ядро ${c.kernel_gap} без модуля AWG — пересобрать до перезагрузки`, "/server/module"] : null,
    d.update ? [`Доступна ${d.update} — обновить`, "/update"] : null,
  ].filter(Boolean);
}

// Трафик за 14 дней: у «Все» при нескольких клиентах — столбцы по клиентам,
// у одного клиента — линия по дням
function trafficBox(t) {
  if (!t || !t.total) return null;
  const rows = (t.clients || []).slice(0, 15), per = {};
  const body = h("div"), chips = h("div", { class: "chips", style: "margin-bottom:6px" });
  const box = h("section", { class: "box", "data-name": "traffic" }, h("header", {}, h("h3", {}, "Трафик · 14 дней"),
    h("div", { class: "r" }, h("b", { class: "mono", style: "color:var(--text)" }, fmtBytes(t.total)))), h("div", { class: "in" }, chips, body));
  function draw() {
    let sel = pref("traffic-client", "");
    if (sel && !rows.some((c) => c.name === sel)) sel = "";
    const pick = (name) => { setPref("traffic-client", name); draw(); };
    chips.replaceChildren(...(rows.length > 1 ? [["", "Все"], ...rows.map((c) => [c.name, c.name])].map(([k, label]) =>
      h("button", { class: k === sel ? "on" : null, onclick: () => pick(k) }, label)) : []));
    if (!sel && rows.length > 1) {
      const labels = rows.length <= 8 ? h("div", { class: "bl", style: `grid-template-columns:repeat(${rows.length},1fr)` },
        rows.map((c) => h("span", {}, c.name))) : null;
      body.replaceChildren(barChart(rows.map((c) => ({ label: c.name, value: c.rx + c.tx,
        detail: `↓ ${fmtBytes(c.rx)} · ↑ ${fmtBytes(c.tx)}` })), { def: 0, axis: labels }));
    } else if (!sel) {
      body.replaceChildren(lineChart(t, { H: 64 }));
    } else if (per[sel]) {
      body.replaceChildren(lineChart(per[sel], { H: 64 }));
    } else {
      body.replaceChildren(h("div", { class: "muted small", style: "padding:20px 0;text-align:center" }, "Загружаю…"));
      call("traffic", "daily", sel, 14).then((d) => { per[sel] = d; draw(); }).catch(() => { setPref("traffic-client", ""); draw(); });
    }
  }
  draw();
  return box;
}

const head = (eyebrow, h1, sub, acts) => h("div", { class: "head" },
  h("div", {}, eyebrow ? h("div", { class: "eyebrow" }, eyebrow) : null, h("h1", {}, h1), sub ? h("div", { class: "sub" }, sub) : null),
  acts && acts.length ? h("div", { class: "hacts" }, acts) : null);
const box = (title, right, ...kids) => h("section", { class: "box" }, h("header", {}, h("h3", {}, title), right ? h("div", { class: "r" }, right) : null),
  h("div", { class: "in" }, kids));
const linkTo = (text, path) => h("a", { onclick: () => go(path) }, text);
const kpi = (label, value, small, d, onclick) => h("div", { class: "kpi" + (onclick ? " tap" : ""), onclick },
  h("div", { class: "eyebrow" }, label), h("div", { class: "v" }, value, small ? (small instanceof Node ? small : h("small", {}, small)) : null),
  h("div", { class: "d" }, d));
// Текстовое значение (ОС, адрес) — переносится, а не режется многоточием
const kpiTxt = (...a) => { const k = kpi(...a); k.querySelector(".v").classList.add("txt"); return k; };
function uptimeParts(sec) {
  sec = Math.max(0, sec || 0);
  const d = Math.floor(sec / 86400), hh = Math.floor(sec % 86400 / 3600), mm = Math.floor(sec % 3600 / 60);
  return d ? [d, "д", hh, "ч"] : hh ? [hh, "ч", mm, "м"] : [mm, "м", null, null];
}
// Канал переключили, пока шёл запрос сводки: её канал — прежний, не затирать им
// только что выбранный (шапка показывала бы «стабильный» до следующей сводки)
let chanGen = 0;
function setStatus(d, gen) {
  S.status = d;
  S.version = d.version || S.version;
  if (gen === undefined || gen === chanGen) {
    S.channel = d.channel || S.channel;
    S.update = d.update || "";           // «↑» прежнего канала — тоже не затирать
  }
  favRefresh();
}

route(/^\/$/, async (ctx) => {
  let clErr = null;
  const gen = chanGen;
  const [me, d, cl, traffic, evlog, wob] = await Promise.all([post("/api/me"), post("/api/status"), post("/api/clients").catch((e) => { clErr = e; return null; }),
    call("traffic", "daily", "all", 14).catch(() => null), callR(["log", "expire", "80"]).catch(() => null),
    call("wgobf", "clients").catch(() => null)]);
  S.me = me;
  setStatus(d, gen);
  if (cl) { S.clients = cl; if (!S.sort) S.sort = cl.sort || "activity"; }
  drawTop();
  const s = d.server || {}, comp = d.components || {}, rows = (cl && cl.rows) || [], r = (cl && cl.route) || {};
  const mdl = exitsModel(rows, r), alerts = homeAlerts(d);
  // Клиенты WG + обфускатора — своя схема под схемой AWG: wgobf0 → напрямую.
  // Трафик — счётчики WireGuard с запуска обфускатора, суточного учёта у него нет
  const wrows = (Array.isArray(wob) ? wob : []).map((c) => Object.assign({}, c, { online: wgobfOnline(c), blocked: false,
    handshake: c.ago != null, today: (c.rx || 0) + (c.tx || 0),
    sub: wgobfOnline(c) ? `в сети · ${fmtBytes((c.rx || 0) + (c.tx || 0))}` : c.ago != null ? `${fmtDur(c.ago)} назад` : "не подключался" }));
  const wmdl = exitsModel(wrows, {}), won = wrows.filter((c) => c.online).length;
  for (const c of rows) c.online = liveOnline(c, S.live);
  const now = new Date();
  const eyebrow = now.toLocaleDateString("ru-RU", { weekday: "long", day: "numeric", month: "long" }) + " · "
    + now.toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });
  const online = rows.filter((c) => c.online).length, byLimit = rows.filter((c) => c.blocked && c.blocked_by === "traffic").length;
  const byExp = rows.filter((c) => c.blocked && c.blocked_by !== "traffic").length;
  const today = rows.reduce((a, c) => a + (c.today || 0), 0), month = rows.reduce((a, c) => a + (c.month || 0), 0);
  const foot = h("div", { class: "foot" }, WEB ? `${me.name} · веб-панель · ${me.bot}` : `${me.name} · ${me.owner ? "владелец" : "админ"} · бот ${me.bot}`);
  // Список клиентов не пришёл — не «Клиентов пока нет» и «Лимитов нет», а честно и с повтором
  const clFail = () => h("div", { class: "card warn", "data-name": "clients-error" },
    h("div", {}, "Не удалось загрузить клиентов" + (clErr && clErr.message ? ": " + clErr.message : "")),
    h("button", { class: "btn-block", onclick: () => render() }, "🔄 Повторить"));

  if (!s.exists) {
    // Сервера ещё нет: компоненты и мастер создания
    return ctx.put(head(eyebrow, "Сервер не создан", comp.installed ? "Компоненты стоят — осталось создать сервер: те же вопросы, что в меню awg2"
      : "Сначала компоненты AmneziaWG, затем сервер", [btn("✨ Создать сервер", () => go("/server/create"), "btn-primary"),
      btn("🖥 Сервер", () => go("/server"))]),
    alerts.length ? h("div", { class: "card warn" }, alerts.map(([a, path]) => h("div", { class: "row", style: "cursor:pointer;padding:3px 0",
      onclick: () => go(path) }, icon("triangle-alert"), a))) : null,
    h("div", { class: "kpis" }, kpiTxt("система", d.os || "—", null, h("span", {}, d.kernel || "")),
      kpi("компоненты", comp.installed ? "есть" : "нет", null, h("span", {}, comp.module ? "модуль " + comp.module : "модуль не собран")),
      kpiTxt("адрес", d.ip || "—", null, h("span", {}, d.host || "")),
      kpi("аптайм", ...((p) => [p[0], p[1] + (p[2] != null ? ` ${p[2]}${p[3]}` : "")])(uptimeParts(d.uptime)), h("span", {}, "сервер не создан"))),
    foot);
  }

  const tun = rows.filter((c) => mdl.of[c.name] !== "direct").length;
  const via = mdl.ex.filter((e) => e.id !== "direct").map((e) => e.grp || e.short).filter((v, i, a) => a.indexOf(v) === i).join("/");
  const [uD, uDu, uH, uHu] = uptimeParts(d.uptime);
  const speedV = h("span", {}, "—"), speedU = h("small", {}, "Мбит/с");
  const speedD = h("span", { style: "display:contents" }, h("span", { class: "dn" }, "↓ приём"), h("span", { class: "up" }, "↑ отдача"));
  const lrx = h("span", {}, "—"), ltx = h("span", {}, "—"), lrxU = h("small", {}, "↓"), ltxU = h("small", {}, "↑");
  const chart = h("div", { class: "lsvg" }, liveSvg(S.live || { rx: [], tx: [] }));
  const livePill = pill("live", "ok"), liveT0 = Date.now();
  const topToday = [...rows].filter((c) => c.today).sort((a, b) => b.today - a.today).slice(0, 5);
  const tmax = Math.max(1, ...topToday.map((c) => c.today));
  const lims = rows.filter((c) => c.limit).map((c) => [c, Math.min(999, Math.round((c.used || 0) * 100 / c.limit))]).sort((a, b) => b[1] - a[1]);
  const nowS = Date.now() / 1000, D30 = 30 * 86400;
  const exps = rows.filter((c) => expLive(c) && c.expires - nowS < D30).sort((a, b) => a.expires - b.expires);
  const events = parseEvents(evlog && evlog.log);
  // Маршруты трафика: схема (по умолчанию) или список — выбор запоминается на устройстве.
  // Есть клиенты WG + обфускатора — в блоке два окна, AWG и Phobos: листаются
  // свайпом и вкладками, открытое окно тоже запоминается
  const routesIn = h("div", { class: wrows.length ? null : "in" }), wgIn = h("div", { "data-name": "wgobf-routes" });
  const tA = h("small", {}), tW = h("small", {});
  const tabs = wrows.length ? [h("button", {}, "AWG ", tA), h("button", {}, "Phobos ", tW)] : [];
  const rlink = (i) => (i ? linkTo("обфускатор →", "/wgobf") : linkTo("туннели →", "/tunnels"));
  const rhLink = h("div", { class: "r" }, rlink(wrows.length && pref("routes-pane", "awg") === "w" ? 1 : 0));
  const vseg = (v) => h("div", { class: "seg rseg", role: "group", "aria-label": "Вид маршрутов" }, [["map", "схема"], ["list", "список"]].map(([k, t]) =>
    h("button", { class: v === k ? "on" : null, "aria-pressed": String(v === k), onclick: () => { setPref("routes", k); drawRoutes(); } }, t)));
  const wcap = () => h("div", { class: "muted small", style: "margin-top:6px" },
    `${won} из ${wrows.length} ${plural(wrows.length, "клиента", "клиентов", "клиентов")} в сети · идут напрямую · трафик с запуска wgobf0`);
  const drawRoutes = () => {
    if (!ctx.live()) return;
    const v = pref("routes", "map") === "list" ? "list" : "map";
    // Окно WG + обфускатора — тот же вид (схема или список), что у маршрутов AWG
    if (wrows.length) {
      tA.textContent = clErr ? "—" : `${rows.filter((c) => c.online).length}/${rows.length}`;
      tW.textContent = `${won}/${wrows.length}`;
      const wtopo = v === "map" ? h("div", { class: "topo" }) : null;
      wgIn.replaceChildren(h("div", { class: "rhead" }, wcap(), vseg(v)), wtopo || wgobfRoutes(wrows));
      if (wtopo) requestAnimationFrame(() => { if (ctx.live()) topology(wtopo, wrows, wmdl, "WG + обфускатор",
        { hub: "wgobf0", hubPath: "/wgobf", exitPath: "/wgobf", key: "w", esub: (n) => `${fmtBytes(n)} с запуска`,
          cpath: (n) => "/wgobf/client/" + encodeURIComponent(n) }); });
    }
    if (clErr) { routesIn.replaceChildren(clFail()); return; }
    if (!rows.length) {
      routesIn.replaceChildren(h("div", { class: "empty" }, "Клиентов AWG пока нет — ", linkTo("создать первого", "/add")));
      return;
    }
    const topo = v === "map" ? h("div", { class: "topo" }) : null;
    routesIn.replaceChildren(
      h("div", { class: "rhead" },
        h("div", { class: "legend" }, v === "map" ? mdl.ex
          // «Напрямую» — в легенде, только если кто-то и правда идёт напрямую (как на схеме)
          .filter((e) => e.id !== "direct" || mdl.ex.length === 1 || rows.some((c) => mdl.of[c.name] === "direct"))
          .map((e) => h("span", { title: e.name }, h("i", { style: `background:${e.c}` }), e.short)) : null),
        vseg(v)),
      ...(topo ? [topo] : routesView(rows, mdl)));
    if (topo) requestAnimationFrame(() => { if (ctx.live()) topology(topo, rows, mdl, `AWG ${s.proto || "?"}` + (srvHidden() ? "" : ` · :${s.port || "?"}`)); });
  };
  const routesBody = wrows.length ? h("div", { class: "in" }, h("div", { class: "seg ptabs", role: "group", "aria-label": "Окно маршрутов" }, tabs),
    swiper([routesIn, wgIn], tabs, pref("routes-pane", "awg") === "w" ? 1 : 0, (i) => {
      setPref("routes-pane", i ? "w" : "awg"); rhLink.replaceChildren(rlink(i)); })) : routesIn;
  const subText = () => [`${rows.filter((c) => c.online).length} из ${rows.length} ${plural(rows.length, "клиента", "клиентов", "клиентов")} в сети`,
    byLimit ? `${byLimit} ${plural(byLimit, "заблокирован", "заблокированы", "заблокированы")} по лимиту` : null,
    byExp ? `${byExp} с истёкшим сроком` : null, wrows.length ? `обфускатор: ${won} из ${wrows.length} в сети` : null,
    alerts.length ? "есть замечания" : "сервер без замечаний"].filter(Boolean).join(" · ");
  const sub = h("span", {}, subText()), kOnline = h("span", {}, String(online));

  ctx.put(
    head(eyebrow, !s.up ? "awg0 не поднят" : alerts.length ? "Нужно внимание" : "Всё работает", sub, [
      btn("🩺 Проверить", () => go("/diag")), btn("➕ Новый клиент", () => go("/add"), "btn-primary")]),
    alerts.length ? h("div", { class: "card warn" }, alerts.map(([a, path]) => h("div", { class: "row", style: "cursor:pointer;padding:3px 0",
      onclick: () => go(path) }, icon("triangle-alert"), a))) : null,
    clErr ? clFail() : null,
    h("div", { class: "kpis" },
      kpi("в сети", kOnline, `/ ${rows.length}`, h("span", {}, tun ? `${tun} через ${via}` : "все напрямую"), () => go("/clients")),
      kpi("сейчас", speedV, speedU, speedD),
      kpi("сегодня", ...fmtBytes(today).split(" "), h("span", {}, `за месяц ${fmtBytes(month)}`)),
      kpi("аптайм сервера", h("span", {}, uD, h("small", {}, uDu), uH != null ? " " + uH : "", uH != null ? h("small", {}, uHu) : null), null,
        h("span", {}, [comp.module ? "модуль " + comp.module : null, d.kernel ? "ядро " + String(d.kernel).split("-")[0] : null].filter(Boolean).join(" · ")))),
    h("div", { class: "g ov1" },
      h("section", { class: "box", "data-name": "routes" }, h("header", {}, h("h3", {}, "Маршруты трафика"), rhLink), routesBody),
      h("section", { class: "box live" }, h("header", {}, h("h3", {}, "Скорость сейчас"), h("div", { class: "r" }, livePill)),
        h("div", { class: "in" }, h("div", { class: "big" }, h("div", { class: "dn" }, lrx, lrxU), h("div", { class: "up" }, ltx, ltxU)), chart,
          h("div", { class: "eyebrow", style: "margin-top:16px" }, "больше всех сегодня"),
          topToday.length ? h("div", { class: "talk" }, topToday.map((c) => h("div", { class: "trow", onclick: () => go("/client/" + encodeURIComponent(c.name)) },
            h("span", { class: "n" }, c.name), h("div", { class: "tbar" }, h("i", { style: `width:${(c.today * 100 / tmax).toFixed(1)}%;background:${mdl.get(mdl.of[c.name]).c}` })),
            h("span", { class: "s mono" }, fmtBytes(c.today))))) : h("div", { class: "muted small" }, "сегодня трафика ещё не было")))),
    h("div", { class: "g ov2" },
      box("Лимиты", lims.length ? `${lims.length} ${plural(lims.length, "клиент", "клиента", "клиентов")}` : null,
        clErr ? h("div", { class: "muted small" }, "Клиенты не загрузились — лимиты неизвестны.")
          : lims.length ? h("div", { class: "rings" }, lims.map(([c, p]) => h("div", { class: "ring", onclick: () => go("/client/" + encodeURIComponent(c.name)) },
          ringSvg(p, 40, 5), h("div", { class: "t" }, h("b", {}, c.name),
            h("span", { style: `color:${p >= 100 ? "var(--red)" : p >= 85 ? "var(--amber)" : "var(--acc)"}` }, p + "%"),
            h("span", { class: "dim" }, ` из ${fmtBytes(c.limit)}`)))))
          : h("div", { class: "muted small" }, "Лимитов нет. Лимит ставится в карточке клиента: исчерпал — клиент блокируется (лимит «в месяц» — до нового месяца).")),
      box("Сроки", "ближайшие 30 дней",
        clErr ? h("div", { class: "muted small" }, "Клиенты не загрузились — сроки неизвестны.") : exps.length ? h("div", { class: "talk" }, exps.map((c) => {
          const left = c.expires - nowS, warn = left < 3 * 86400;
          return h("div", { class: "trow", onclick: () => go("/client/" + encodeURIComponent(c.name)) }, h("span", { class: "n" }, c.name),
            h("div", { class: "tbar" }, h("i", { style: `width:${Math.max(3, Math.min(100, left * 100 / D30)).toFixed(1)}%;background:${warn ? "var(--amber)" : "var(--acc)"}` })),
            h("span", { class: "s mono", style: warn ? "color:var(--amber)" : null }, expShort(c.expires)));
        })) : h("div", { class: "muted small" }, "В ближайшие 30 дней ни у кого срок не истекает."),
        h("div", { class: "muted small", style: "margin-top:14px" }, "Истёкший клиент не удаляется — блокируется; новый срок возвращает его.")),
      box("События", linkTo("журнал →", "/log/expire"),
        events.length ? h("div", { class: "feed" }, events.slice(0, 6).map(evRow))
          : h("div", { class: "muted small" }, "Блокировок по сроку и лимиту ещё не было."))),
    trafficBox(traffic),
    box("Сервер", linkTo("подробнее →", "/server"), h("div", { class: "params" }, [
      ["протокол", "AWG " + (s.proto || "?")], ["профиль", s.profile_label || s.profile || "—"], ["порт", (s.port || "?") + "/udp"],
      ["MTU", String(s.mtu || "—")], ["мимикрия", s.mimicry && s.mimicry !== "none" ? s.mimicry : "без I1-I5"],
      ["DNS", (d.tunnels || {}).dns === "up" ? "dnscrypt" : "как у клиента"], ["подсеть", s.net || "—"], ["система", d.os || "—"]]
      .map(([k, v]) => h("div", {}, h("span", {}, k), h("b", { title: v }, v))))),
    foot);
  drawRoutes();
  // Ширина окна поменялась — схема перерисовывается под неё
  // Слушатель один на окно: прежний снимается при новом заходе на экран и когда экран закрыт
  if (S.onResize) window.removeEventListener("resize", S.onResize);
  const onResize = () => { if (!ctx.live()) { window.removeEventListener("resize", onResize); if (S.onResize === onResize) S.onResize = null; return; } clearTimeout(onResize.t); onResize.t = setTimeout(drawRoutes, 150); };
  S.onResize = onResize;
  window.addEventListener("resize", onResize);
  liveLoop(ctx, (L) => {
    // Отключился или подключился — схема, счётчик и подзаголовок меняются на лету
    let moved = false;
    for (const c of rows) {
      const v = liveOnline(c, L);
      if (v === c.online) continue;
      c.online = v; moved = true;
      if (!v && L.act[c.name]) c.ago = Math.round((Date.now() - L.act[c.name]) / 1000);
    }
    if (moved) { kOnline.textContent = String(rows.filter((c) => c.online).length); sub.textContent = subText(); drawRoutes(); }
    // Последний замер старше 10 с — связи нет: скорость не застывает на старом числе
    const stale = Date.now() - Math.max(L.at || 0, liveT0) > 10000;
    livePill.className = "pill " + (stale ? "bad" : "ok");
    livePill.textContent = stale ? "нет связи" : "live";
    if (stale) { [lrx, ltx, speedV].forEach((el) => { el.textContent = "—"; }); speedD.replaceChildren(h("span", {}, "нет связи")); return; }
    const rx = L.rx.length ? L.rx[L.rx.length - 1] : 0, tx = L.tx.length ? L.tx[L.tx.length - 1] : 0;
    if (!L.rx.length) return;
    const [a, au] = fmtRate(rx), [b, bu] = fmtRate(tx), [c, cu] = fmtRate(rx + tx);
    lrx.textContent = a; lrxU.textContent = "↓ " + au; ltx.textContent = b; ltxU.textContent = "↑ " + bu;
    speedV.textContent = c; speedU.textContent = cu;
    speedD.replaceChildren(h("span", { class: "dn" }, `↓ ${rateText(rx)}`), h("span", { class: "up" }, `↑ ${rateText(tx)}`));
    chart.replaceChildren(liveSvg(L));
  });
});

// ── Клиенты ───────────────────────────────────────────────
const FILTERS = [["all", "Все"], ["online", "Онлайн"], ["blocked", "Заблок."], ["mon", "Мониторинг"]];
const EXPIRES = [["", "♾ Бессрочно"], ["+1h", "1 час"], ["+1d", "1 день"], ["+7d", "7 дней"], ["+30d", "30 дней"]];

const blockedWord = (c) => (c.blocked_by === "traffic" ? "лимит исчерпан" : "срок истёк");
function seen(c) {
  if (c.blocked) return blockedWord(c);
  if (c.online) return "онлайн";
  if (c.handshake) return `был ${fmtDur(c.ago)} назад`;
  return "не подключался";
}
function expShort(ts) {
  const left = ts - Date.now() / 1000;
  return left > 0 ? fmtDur(left) : "истёк";
}
function sortRows(rows, mode) {
  const byName = (a, b) => a.name.localeCompare(b.name, "ru", { sensitivity: "base" });
  if (mode === "name") return [...rows].sort(byName);
  return [...rows].sort((a, b) => (a.blocked - b.blocked) || (b.online - a.online) || ((b.handshake || 0) - (a.handshake || 0)) || byName(a, b));
}
async function loadClients() {
  S.clients = await post("/api/clients");
  if (!S.sort) S.sort = S.clients.sort || "activity";
  return S.clients;
}
const byName = (name) => (S.clients && S.clients.rows || []).find((c) => c.name === name);
// Веб-панель без Telegram-бота: уведомлений и автобэкапов в чат не будет
const noBot = () => !!WEB && !(S.me && S.me.tg_bot);

// Состояние клиента: рамка и точка карточки, пометка справа, чипы
const clientState = (c) => (c.blocked ? "bad" : c.online ? "on" : "");
function statusPill(c) {
  if (c.blocked) return pill(blockedWord(c), "bad");
  if (c.online) return pill("онлайн · " + fmtDur(c.ago), "ok");
  if (c.handshake) return pill(fmtDur(c.ago) + " назад");
  return pill("не подключался");
}
function routeTag(c, r) {
  const t = { warp: "WARP", xray: "Xray" }[r.kind];
  if (t && r.kind === "xray" && c.xray !== false && c.xray_out) return tag("Xray: " + c.xray_out, "ok", "network");
  if (t) return c[r.kind] !== false ? tag(t, "ok", "network") : tag("мимо " + t, "", "network");
  if (r.kind === "tun2socks") return tag("tun2socks", "ok", "network");
  if (r.kind !== "exits") return null;
  const v = c.exit_choice || "shared";
  return v === "off" ? tag("мимо нод", "", "door-open") : tag(v === "shared" ? "общий выход" : "нода " + v, "ok", "door-open");
}
function clientTags(c) {
  const left = c.expires ? c.expires - Date.now() / 1000 : 0;
  return [
    c.mimicry && c.mimicry !== "none" ? tag(c.mimicry, "accent", "drama") : tag("без I1-I5"),
    expLive(c) ? tag(expShort(c.expires), left < 3 * 86400 ? "warn" : "", "hourglass") : null,
    c.limit ? tag(`лимит ${Math.min(999, Math.round(c.used * 100 / c.limit))}%`, c.used >= c.limit * 0.9 ? "warn" : "", "gauge") : null,
    routeTag(c, (S.clients && S.clients.route) || {}),
    c.mon ? tag("мониторинг", "", "bell") : null,
  ];
}
async function removeClients(btn, names, after) {
  const list = names.slice(0, 5).join(", ") + (names.length > 5 ? ` и ещё ${names.length - 5}` : "");
  if (!await confirmTg(names.length === 1 ? `Удалить клиента ${names[0]}? Его конфиг перестанет работать.`
    : `Удалить клиентов: ${names.length}?\n${list}\n\nИх конфиги перестанут работать.`)) return;
  await busy(btn, async () => {
    const r = await post("/api/client/del", { names });
    // Сервер отвечает именами, которые удалил на самом деле
    const gone = Array.isArray(r && r.data) ? r.data.filter((n) => names.includes(n)) : names;
    haptic();
    if (gone.length === names.length) toast(names.length === 1 ? `Удалён: ${names[0]}` : `Удалено: ${names.length}`);
    else if (!gone.length) toast("Не удалось удалить: " + list, 4000);
    else toast(`Удалено ${gone.length} из ${names.length}; остались: ${names.filter((n) => !gone.includes(n)).join(", ")}`, 5000);
    after();
  });
}

// Аватар клиента: буквы имени, цвет — от имени; точка — в сети / заблокирован
const avaColor = (name) => { let x = 7; for (const ch of name) x = (x * 31 + ch.charCodeAt(0)) >>> 0; return `hsl(${x % 360}, 62%, 66%)`; };
const ava = (c) => h("div", { class: "ava " + clientState(c), style: `background:${avaColor(c.name)}` },
  c.name.replace(/[^A-Za-z0-9]/g, "").slice(0, 2) || "?");

const CLIENTS_RE = route(/^\/clients$/, async (ctx) => {
  await loadClients();
  const D = () => S.clients;                 // карточка справа обновляет S.clients — список рисуется заново
  // На ПК — таблица или карточки сеткой; на телефоне и в Mini App — карточки или строки
  const wide = desk(), vkey = wide ? "view-desk" : "view";
  S.view = pref(vkey, wide ? "table" : "cards");
  if (wide && S.view === "list") S.view = "table";
  if (!wide && S.view === "table") S.view = "cards";
  const tabs = h("div"), toolbar = h("div", { class: "ctools" }), list = h("div"), bar = h("div", { class: "bar", style: "display:none" });
  const headBox = h("div");
  const search = h("input", { type: "search", placeholder: "Поиск по имени, IP, заметке", value: S.q, "aria-label": "Поиск",
    oninput: () => { S.q = search.value.trim().toLowerCase(); draw(); } });
  // Поле поиска остаётся в панели инструментов навсегда: пересоздай его draw() — фокус пропал бы после каждой буквы
  toolbar.append(h("div", { class: "search" }, icon("search"), search));
  const count = (k) => D().rows.filter((c) => k === "all" || (k === "online" && c.online) || (k === "blocked" && c.blocked)
    || (k === "mon" && c.mon)).length;

  function visible() {
    return sortRows(D().rows, S.sort).filter((c) =>
      (S.filter === "all" || (S.filter === "online" && c.online) || (S.filter === "blocked" && c.blocked) || (S.filter === "mon" && c.mon))
      && (!S.q || `${c.name} ${c.ip} ${c.note || ""}`.toLowerCase().includes(S.q)));
  }
  const toggle = (c) => { S.select.has(c.name) ? S.select.delete(c.name) : S.select.add(c.name); draw(); };
  const open = (c) => (S.select ? toggle(c) : go("/client/" + encodeURIComponent(c.name)));
  const mark = (c) => h("div", { class: "check" + (S.select.has(c.name) ? " on" : "") }, S.select.has(c.name) ? icon("check") : null);
  function card(c) {
    const enc = encodeURIComponent(c.name);
    return ecard({ state: clientState(c), cls: S.select && S.select.has(c.name) ? "sel" : "", name: c.name,
      attrs: { "data-name": c.name }, onopen: () => open(c), right: S.select ? mark(c) : statusPill(c),
      meta: clientTags(c), lines: [`${c.ip} · ↓ ${fmtBytes(c.rx)} · ↑ ${fmtBytes(c.tx)}` + (c.today ? ` · сегодня ${fmtBytes(c.today)}` : "")],
      note: c.note,
      acts: S.select ? null : [act("qr-code", "QR", () => go(`/client/${enc}/qr`)),
        act("square-pen", "Изменить", () => go(`/client/${enc}`)),
        act("trash-2", "Удалить", (b) => removeClients(b, [c.name], render), "bad")] });
  }
  // Строка таблицы (ПК): клиент, состояние, трафик, лимит, срок, маршрут, действия
  const sortHead = (label, mode) => h("th", { class: "sort" + (S.sort === mode ? " on" : ""), title: "Сортировать",
    onclick: () => { S.sort = mode; post("/api/settings", { sort: mode }).catch(() => {}); draw(); } }, label);
  function trow(c, mdl) {
    const enc = encodeURIComponent(c.name), sel = S.select && S.select.has(c.name);
    const pct = c.limit ? Math.min(999, Math.round((c.used || 0) * 100 / c.limit)) : 0;
    const op = (ic, label, fn, cls) => h("button", { class: cls || null, title: label, "aria-label": label,
      onclick: (ev) => { ev.stopPropagation(); fn(ev.currentTarget); } }, icon(ic));
    const left = c.expires ? c.expires - Date.now() / 1000 : 0;
    const expActive = expLive(c);
    return h("tr", { class: sel ? "sel" : null, "data-name": c.name, onclick: () => open(c) },
      S.select ? h("td", {}, mark(c)) : null,
      h("td", {}, h("div", { class: "who" }, ava(c), h("div", { style: "min-width:0" }, h("b", {}, c.name, c.mon ? " 🔔" : ""),
        h("span", { class: "note" }, [c.ip, c.note].filter(Boolean).join(" · "))))),
      h("td", {}, statusPill(c)),
      h("td", { class: "num" }, c.today != null ? `${fmtBytes(c.today)} сегодня` : "—", h("br"),
        h("span", { class: "muted" }, `↓ ${fmtBytes(c.rx)} · ↑ ${fmtBytes(c.tx)}`)),
      h("td", {}, c.limit ? h("div", { class: "lim", title: limitText(c) }, ringSvg(pct, 26, 4), pct + "%") : h("span", { class: "muted" }, "—")),
      h("td", { class: "num", style: expActive && left < 3 * 86400 ? "color:var(--amber)" : null },
        expActive ? expShort(c.expires) : c.expires ? "истёк" : "∞"),
      h("td", {}, routeChip(c, mdl), c.mimicry && c.mimicry !== "none" ? h("div", { class: "muted small mono" }, c.mimicry) : null),
      h("td", {}, S.select ? null : h("div", { class: "ops" },
        op("qr-code", "Конфиг и QR", () => go(`/client/${enc}/qr`)),
        op("square-pen", "Изменить", () => go(`/client/${enc}`)),
        op("trash-2", "Удалить", (b) => removeClients(b, [c.name], render), "bad"))));
  }
  const table = (rows) => {
    const mdl = exitsModel(D().rows, D().route);
    return h("table", { class: "ctable" },
      h("thead", {}, h("tr", {}, S.select ? h("th", {}) : null, sortHead("Клиент", "name"), sortHead("Состояние", "activity"),
        h("th", {}, "Трафик"), h("th", {}, "Лимит"), h("th", {}, "Срок"), h("th", {}, "Маршрут"), h("th", {}))),
      h("tbody", {}, rows.map((c) => trow(c, mdl))));
  };
  function row(c) {
    return h("div", { class: "item", "data-name": c.name, onclick: () => open(c) },
      S.select ? mark(c) : ava(c),
      h("div", { class: "main" }, h("div", { class: "title" }, c.name + (c.mon ? " 🔔" : "")),
        h("div", { class: "sub" }, [c.ip, seen(c), expLive(c) ? "⏳ " + expShort(c.expires) : null, c.note].filter(Boolean).join(" · "))),
      h("div", { class: "side" }, "↓" + fmtBytes(c.rx), h("br"), "↑" + fmtBytes(c.tx)));
  }
  function exportBtn() {
    return h("button", { disabled: !D().rows.length || null, onclick: (ev) => busy(ev.currentTarget, async () => {
      await deliver({ what: "export" }, "Архив всех конфигов — в чате с ботом");
    }) }, icon("download"), "Экспорт");
  }
  function createBtn() {
    return h("button", { class: "btn-primary", onclick: async () => {
      const v = await sheet("Новые клиенты", [{ label: "➕ Один клиент", value: "/add" }, { label: "👥 Несколько сразу", value: "/bulk" }]);
      if (v) go(v);
    } }, icon("plus"), "Новый клиент");
  }
  function draw() {
    const d = D(), rows = visible();
    const today = d.rows.reduce((a, c) => a + (c.today || 0), 0), n = d.rows.length;
    const net = S.status && S.status.server && S.status.server.net;
    headBox.replaceChildren(head(net ? `awg0 · ${net}` : "awg0", "Клиенты",
      `${n} ${plural(n, "конфиг", "конфига", "конфигов")} · ${count("online")} в сети` + (count("blocked") ? ` · ${count("blocked")} заблокировано` : "")
      + ` · сегодня ${fmtBytes(today)}`, [exportBtn(), createBtn()]));
    tabs.replaceChildren(tabsBar(FILTERS.map(([k, label]) => [k, label, count(k)]), S.filter, (k) => { S.filter = k; draw(); }));
    const views = wide ? [["table", "list", "Таблица"], ["cards", "layout-grid", "Карточки"]]
      : [["cards", "layout-list", "Карточки"], ["list", "list", "Список"]];
    while (toolbar.children.length > 1) toolbar.lastChild.remove();       // всё, кроме поиска
    toolbar.append(
      segBar(views, S.view, (v) => { S.view = v; setPref(vkey, v); draw(); }),
      h("button", { title: "Сортировка: " + (S.sort === "name" ? "по имени" : "по активности"), "aria-label": "Сортировка", onclick: () => {
        S.sort = S.sort === "name" ? "activity" : "name";
        post("/api/settings", { sort: S.sort }).catch(() => {});
        toast(S.sort === "name" ? "По имени" : "По активности");
        draw();
      } }, icon(S.sort === "name" ? "arrow-down-a-z" : "activity")),
      h("button", { class: S.select ? "btn-primary" : null, onclick: () => { S.select = S.select ? null : new Set(); draw(); } },
        icon("list-checks"), "Выбрать"));
    const noSrv = S.status && S.status.server && S.status.server.exists === false;
    const empty = h("div", { class: "card empty" }, d.rows.length ? "Никого не нашлось"
      : noSrv ? ["Сервер ещё не создан — ", linkTo("создать сервер", "/server/create")] : "Клиентов пока нет — создай первого");
    list.className = S.view === "cards" ? "clist" : S.view === "table" ? "tscroll" : "";
    list.replaceChildren(...(!rows.length ? [empty] : S.view === "table" ? [table(rows)] : S.view === "list"
      ? [h("div", { class: "card list" }, rows.map(row))] : rows.map(card)));
    // Строка, чья карточка открыта справа, — подсвечена
    const cur = (curPath().match(/^\/client\/([^/]+)/) || [])[1];
    if (cur) list.querySelectorAll("[data-name]").forEach((el) => el.classList.toggle("cur", el.dataset.name === decodeURIComponent(cur)));
    const picked = S.select ? rows.filter((c) => S.select.has(c.name)).map((c) => c.name) : [];
    if (S.select) {
      bar.style.display = "";
      bar.replaceChildren(
        h("button", { onclick: () => { const all = rows.every((c) => S.select.has(c.name));
          rows.forEach((c) => (all ? S.select.delete(c.name) : S.select.add(c.name))); draw(); } }, "Все"),
        h("button", { class: "btn-danger", disabled: !picked.length || null,
          onclick: (ev) => removeClients(ev.currentTarget, picked, () => { S.select = null; render(); }) },
        icon("trash-2"), `Удалить ${picked.length || ""}`),
        h("button", { onclick: () => { S.select = null; draw(); } }, "Отмена"));
    } else {
      bar.style.display = "none";
    }
  }
  ctx.put(headBox, tabs, toolbar, list, bar);
  draw();
  // Список на месте — карточка клиента на ПК откроется поверх него, без новой загрузки
  if (ctx.live()) S.listShown = true;
  // Обнуляется, когда на место списка приходит другой экран (show в роутере)
  S.listRedraw = () => { if (S.clients) draw(); };
});

// Карточка клиента
route(/^\/client\/([^/]+)$/, async (ctx, name) => {
  await loadClients();
  const c = byName(name);
  if (!c) return ctx.put(h("div", { class: "empty" }, `Клиента ${name} нет`), h("button", { class: "btn-block", onclick: () => replace("/clients") }, "К списку"));
  const r = S.clients.route || {};
  const enc = encodeURIComponent(name);
  const chartBox = h("div");
  call("traffic", "daily", name, 30).then((t) => t && t.total && chartBox.replaceChildren(lineChart(t))).catch(() => {});

  async function setExpire(btn) {
    const v = await sheet("Срок действия", [
      { label: c.expires ? "♾ Снять срок" + (c.blocked ? " и разблокировать" : "") : "♾ Бессрочно", value: "none" },
      ...EXPIRES.slice(1).map(([val, label]) => ({ label: "⏳ " + label, value: val })),
      { label: "📅 До даты…", value: "date" }]);
    if (!v) return;
    if (v === "date") return go(`/client/${enc}/date`);
    await busy(btn, async () => {
      await (v === "none" ? call("client", "unexpire", name) : call("client", "expire", name, v));
      haptic(); toast("Срок обновлён"); render();
    });
  }
  async function setLimit(btn) {
    const v = await sheet("Лимит трафика · " + name, [
      ...["10", "50", "100", "300"].map((g) => ({ label: `📶 ${g} ГБ в месяц`, value: g + "G" })),
      { label: "✏️ Свой размер или «всего»…", value: "custom" },
      ...(c.limit ? [{ label: "🔄 Обнулить счётчик", value: "reset" }, { label: "♾ Снять лимит", value: "off" }] : [])]);
    if (!v) return;
    if (v === "custom") return go(`/client/${enc}/limit`);
    await busy(btn, async () => {
      await (v === "reset" ? call("client", "limit-reset", name) : call("client", "limit", name, v, "month"));
      haptic(); toast(v === "off" ? "Лимит снят" : v === "reset" ? "Счётчик обнулён" : "Лимит установлен"); render();
    });
  }
  // Маршрут клиента — выбор прямо в карточке: варианты работающего туннеля
  function routeCard() {
    const kind = r.kind;
    const pick = (opts, cur, apply) => h("div", { class: "chips rchips" }, opts.map(([v, l]) => h("button", {
      class: v === cur ? "on" : null, "data-v": v, title: l, onclick: (ev) => (v === cur ? null : busy(ev.currentTarget, async () => {
        await apply(v); haptic(); toast(`Маршрут ${name}: ${l}`); render();
      })) }, l)));
    let body;
    if (!kind) body = h("div", { class: "muted small" }, "Туннели выключены — клиент идёт напрямую через сервер. ", linkTo("Туннели →", "/tunnels"));
    else if (kind === "tun2socks") body = h("div", { class: "muted small" }, "Через tun2socks идут все клиенты — выбирать нечего.");
    else if (kind === "exits") {
      body = [pick([["off", "Напрямую"], ["shared", "Общий выход"], ...(r.nodes || []).map((n) => [n, "Нода " + n])], c.exit_choice || "shared",
        (v) => call("exits", "client", name, v)),
      r.mode !== "peers" ? hint("Сейчас через exit-ноды идут все клиенты. Выбор переведёт их в режим «выбранные» — остальные останутся на общем выходе.") : null];
    } else if (kind === "xray" && r.per_client && (r.tags || []).length >= 2) {
      // Свой выход Xray клиенту; «по умолчанию» — общий выход или балансировщик
      const main = r.main === "balancer" ? "балансировщик" : r.main;
      body = pick([["default", "По умолчанию" + (main ? ` (${main})` : "")], ...r.tags.map((t) => ["x:" + t, t]), ["off", "Напрямую"]],
        c.xray === false ? "off" : c.xray_out ? "x:" + c.xray_out : "default",
        (v) => {
          if (v === "off") return call("tunnels", "client", "xray", name, "off");
          toast("Перенастраиваю Xray…", 4000);
          return call("xray", "client", name, v === "default" ? "default" : v.slice(2));
        });
    } else {
      const t = kind === "warp" ? "WARP" : "Xray";
      body = pick([["on", "Через " + t], ["off", "Напрямую"]], c[kind] !== false ? "on" : "off", (v) => call("tunnels", "client", kind, name, v));
    }
    return h("div", { class: "card rcard" }, h("div", { class: "eyebrow" }, "маршрут"), body);
  }

  const area = (a, ...el) => h("div", { class: "a-" + a }, el);
  ctx.put(
    ctx.drawer ? null : title(name, statusPill(c)),
    h("div", { class: "row", style: "flex-wrap:wrap;gap:6px;margin:-4px 2px 12px" }, ctx.drawer ? statusPill(c) : null, clientTags(c)),
    h("div", { class: "cgrid" }, area("stats", statGrid([
      [fmtBytes(c.rx), "Принято ↓", "от клиента"],
      [fmtBytes(c.tx), "Отдано ↑", "клиенту"],
      [c.handshake ? fmtDur(c.ago) : "—", "Рукопожатие", c.handshake ? (c.online ? "назад · онлайн" : "назад") : "не было"],
      [c.expires ? expShort(c.expires) : "∞", "Срок", c.expires ? fmtTime(c.expires) : "бессрочно"],
    ])),
    area("info", h("div", { class: "card" },
      kv("IP", h("span", { class: "mono" }, c.ip)),
      c.endpoint ? kv("Адрес клиента", h("span", { class: "mono" }, c.endpoint.replace(/:\d+$/, ""))) : null,
      kv("Мимикрия", h("span", { class: "mono" }, !c.mimicry || c.mimicry === "none" ? "без I1-I5" : c.mimicry)),
      c.note ? kv("Заметка", c.note) : null), routeCard()),
    area("traf", h("div", { class: "card" },
      kv("За месяц", fmtBytes(c.month)), kv("Сегодня", fmtBytes(c.today)),
      kv("Лимит", c.limit ? limitText(c) : "нет"), c.limit ? meter(c.used, c.limit) : null, chartBox)),
    // Сообщает Telegram-бот: в веб-панели без бота присылать некому — так и говорим
    area("mon", switchRow("Мониторинг активности", noBot() ? "уведомления присылает Telegram-бот — он не установлен"
      : "уведомления в чат, когда клиент пропал и вернулся", c.mon, async (on) => {
      await post("/api/client/mon", { name, on });
      toast(!on ? "🔕 Мониторинг выключен" : noBot() ? "🔔 Включено — но сообщать некому: Telegram-бот не установлен"
        : "🔔 Бот сообщит, когда клиент пропадёт и вернётся", 3500);
    })),
    area("acts", h("div", { class: "actions" },
      h("button", { class: "btn-primary", onclick: () => go(`/client/${enc}/qr`) }, icon("qr-code"), "Конфиг и QR"),
      h("button", { onclick: () => go(`/client/${enc}/rename`) }, "✏️ Имя"),
      h("button", { onclick: (ev) => setExpire(ev.currentTarget) }, "⏳ Срок"),
      h("button", { onclick: (ev) => setLimit(ev.currentTarget) }, "📶 Лимит"),
      h("button", { onclick: () => go(`/client/${enc}/mimicry`) }, "🎭 Мимикрия"),
      h("button", { onclick: () => go(`/client/${enc}/note`) }, "📝 Заметка"))),
    // После удаления — шаг назад к списку, а не второй список поверх первого
    area("del", h("button", { class: "btn-danger btn-block", onclick: (ev) => removeClients(ev.currentTarget, [name],
      () => backWith((p) => (/^\/client\//.test(p) ? "/clients" : null))) },
      "🗑 Удалить клиента"))));
});

// Конфиг файлом; в веб-панели рядом — тот же файл в ZIP: AmneziaWG на телефоне
// берёт .conf или .zip. В Telegram файл и так приходит в чат как «имя.conf»
const confBtns = (name, primary = true) => {
  const conf = h("button", { class: primary ? "btn-primary" : null, onclick: (ev) => busy(ev.currentTarget, async () => {
    await deliver({ what: "conf", name }, "Файл и QR — в чате с ботом");
  }) }, TO("✉️ Отправить файл в чат", "⬇️ Скачать .conf"));
  if (!WEB) { conf.classList.add("btn-block"); return conf; }
  return h("div", { class: "even2 confbtns" }, conf,
    h("button", { onclick: (ev) => busy(ev.currentTarget, () => deliver({ what: "conf_zip", name })) }, "🗜 Скачать ZIP"));
};

route(/^\/client\/([^/]+)\/qr$/, async (ctx, name) => {
  const d = await post("/api/client/qr", { name });
  ctx.put(
    title("📄 " + name),
    d.png ? h("img", { class: "qr", src: "data:image/png;base64," + d.png, alt: "QR" })
      : h("div", { class: "card muted" }, "Конфиг длинный — в читаемый QR не влезает. Импортируй файлом."),
    h("div", { class: "muted small", style: "text-align:center;margin:6px 0 10px" }, "AmneziaVPN / AmneziaWG → добавить → QR или файл"),
    confBtns(name),
    copyBtn("Скопировать конфиг", d.text),
    h("pre", { class: "small" }, d.text));
});

route(/^\/client\/([^/]+)\/rename$/, async (ctx, name) => {
  const input = h("input", { value: name, maxlength: 32, autocapitalize: "off", autocomplete: "off" });
  ctx.put(title("✏️ Новое имя"), h("label", {}, "Латиница, цифры, _ и -, до 32"), input,
    enterTo(h("button", { class: "btn-primary btn-block", onclick: (ev) => busy(ev.currentTarget, async () => {
      const v = input.value.trim();
      if (!/^[A-Za-z0-9_-]{1,32}$/.test(v)) throw new Error("Имя: латиница, цифры, _ и -, до 32 символов");
      if (v !== name) await post("/api/client/rename", { old: name, new: v });
      // Карточка со старым именем в истории заменяется новой: «Назад» не ведёт на «Клиента bob нет»
      haptic(); backWith(() => "/client/" + encodeURIComponent(v));
    }) }, "Сохранить"), input));
  input.focus();
});

route(/^\/client\/([^/]+)\/note$/, async (ctx, name) => {
  await loadClients();
  const c = byName(name) || {};
  const ta = h("textarea", { maxlength: 190 }, c.note || "");
  ctx.put(title("📝 Заметка · " + name), h("label", {}, "До 190 символов; пусто — удалить" + (WEB ? " · Ctrl+Enter — сохранить" : "")), ta,
    enterTo(h("button", { class: "btn-primary btn-block", onclick: (ev) => busy(ev.currentTarget, async () => {
      await post("/api/client/note", { name, text: ta.value.trim() }); haptic(); back();
    }) }, "Сохранить"), ta));
  ta.focus();
});

// Лимит в поле — так, чтобы сохранение без правки дало те же байты (как
// parse_size в awg2: int(число × единица)); «1.3G» из fmtBytes менял лимит
const sizeText = (n) => {
  for (const [u, m] of [["T", 2 ** 40], ["G", 2 ** 30], ["M", 2 ** 20], ["K", 1024]]) {
    const s = String(+(n / m).toFixed(3));
    if (n >= m && s.split(".")[0].length <= 7 && Math.trunc(parseFloat(s) * m) === n) return s + u;
  }
  return String(+(n / 2 ** 30).toFixed(3)) + "G";
};

route(/^\/client\/([^/]+)\/limit$/, async (ctx, name) => {
  await loadClients();
  const c = byName(name) || {};
  let period = c.period || "month";
  const input = h("input", { placeholder: "50G", value: c.limit ? sizeText(c.limit) : "",
    autocapitalize: "off", autocomplete: "off" });
  const seg = h("div");
  const drawSeg = () => seg.replaceChildren(segText([["month", "В месяц"], ["total", "Всего"]], period, (p) => { period = p; drawSeg(); }));
  drawSeg();
  ctx.put(title("📶 Лимит · " + name),
    h("label", {}, "Размер: 50G, 500MB, 1.5T; число без буквы — гигабайты"), input, seg,
    hint("Исчерпал лимит — клиент блокируется, как истёкший. «В месяц» — счётчик обнуляется 1-го числа, и клиент "
      + "разблокируется сам; «всего» — считается с этой минуты, без сброса."),
    enterTo(h("button", { class: "btn-primary btn-block", onclick: (ev) => busy(ev.currentTarget, async () => {
      const v = input.value.trim().replace(/\s+/g, "").toUpperCase().replace("ГБ", "G").replace("МБ", "M").replace("ТБ", "T").replace("КБ", "K");
      // Как parse_size в awg2: 50G, 50GB, 50GiB, 500M; число без буквы — гигабайты
      if (!/^\d{1,7}([.,]\d{1,3})?([KMGT](I?B)?)?$/.test(v)) throw new Error("Размер: например 50G или 500M");
      await call("client", "limit", name, v, period); haptic(); toast("Лимит установлен"); back();
    }) }, "Сохранить"), input));
  input.focus();
});

route(/^\/client\/([^/]+)\/date$/, async (ctx, name) => {
  const def = new Date(Date.now() + 30 * 86400e3);
  def.setMinutes(def.getMinutes() - def.getTimezoneOffset());
  const input = h("input", { type: "datetime-local", value: def.toISOString().slice(0, 16) });
  ctx.put(title("📅 Срок · " + name), h("label", {}, "Клиент заблокируется в это время (время этого устройства)"), input,
    enterTo(h("button", { class: "btn-primary btn-block", onclick: (ev) => busy(ev.currentTarget, async () => {
      const ts = Math.floor(new Date(input.value).getTime() / 1000);
      if (!ts || ts < Date.now() / 1000 + 60) throw new Error("Нужна дата в будущем");
      await call("client", "expire", name, ts); haptic(); toast("Срок обновлён"); back();
    }) }, "Сохранить"), input));
});

// Мимикрия: профиль и уровень; новый конфиг — сразу на экран QR
async function mimicryPicker(onPick) {
  const [profiles, srv] = await Promise.all([call("mimicry").then((x) => x || []), call("server", "info").catch(() => ({}))]);
  const srvMim = (srv && srv.mimicry) || "none", srvLevel = String((srv && srv.obf_level) || "1");
  const srvLabel = (profiles.find((p) => p.id === srvMim) || {}).label || srvMim;
  // По умолчанию — уровень сервера; выбранный уровень действует и на «Как у сервера»
  let level = srvLevel === "2" ? "2" : "3";
  const lv = h("div", { class: "chips" });
  const drawLv = () => lv.replaceChildren(...[["3", "Цепочка I1-I5"], ["2", "Только I1"]].map(([v, l]) =>
    h("button", { class: "chip" + (level === v ? " on" : ""), onclick: () => { level = v; drawLv(); } }, l)));
  drawLv();
  return [
    h("div", { class: "muted small", style: "margin:0 4px 6px" }, "Пакеты I1-I5 перед рукопожатием — под какой протокол маскироваться. Keenetic читает только I1, WireSock — ни одного."),
    h("label", {}, "Уровень"), lv,
    h("div", { class: "card list" },
      h("div", { class: "item", onclick: () => onPick(srvMim === "none" || srvLevel === "1" ? "server" : `server:${level}`) },
        h("div", { class: "main" }, h("div", { class: "title" }, "Как у сервера"),
          h("div", { class: "sub" }, srvMim === "none" || srvLevel === "1" ? "у сервера без I1-I5"
            : `${srvLabel} — у сервера ${srvLevel === "2" ? "только I1" : "цепочка"}, уровень — выбранный выше`))),
      h("div", { class: "item", onclick: () => onPick("none") }, h("div", { class: "main" }, h("div", { class: "title" }, "Без I1-I5"))),
      profiles.map((p) => h("div", { class: "item", onclick: () => onPick(`${p.id}:${level}`) },
        h("div", { class: "main" }, h("div", { class: "title" }, p.label), h("div", { class: "sub" }, p.hint))))),
  ];
}

route(/^\/client\/([^/]+)\/mimicry$/, async (ctx, name) => {
  // Смена — с вопросом (старый конфиг перестанет подключаться) и одна за раз:
  // двойной тап не шлёт второй запрос, список на время запроса не нажимается
  const box = h("div");
  let running = false;
  box.append(...await mimicryPicker(async (spec) => {
    if (running) return;
    running = true;
    try {
      if (!await confirmTg(`Сменить мимикрию ${name}? Старый конфиг перестанет подключаться — понадобится новый (QR или файл).`)) return;
      box.classList.add("reloading");
      await busy(null, async () => {
        toast("Генерирую мимикрию…", 4000);
        await call("client", "mimicry", name, spec);
        haptic(); toast("Мимикрия обновлена — старый конфиг больше не подключится", 3500);
        replace(`/client/${encodeURIComponent(name)}/qr`);
      });
    } finally { running = false; box.classList.remove("reloading"); }
  }));
  ctx.put(title("🎭 Мимикрия · " + name), box);
});

// ── Новый клиент ──────────────────────────────────────────
function expireField() {
  const sel = h("select", {}, EXPIRES.map(([v, l]) => h("option", { value: v }, l)), h("option", { value: "date" }, "📅 До даты…"));
  const date = h("input", { type: "datetime-local", style: "display:none;margin-top:8px" });
  sel.onchange = () => { date.style.display = sel.value === "date" ? "" : "none"; };
  const value = () => {
    if (sel.value !== "date") return sel.value;
    const ts = Math.floor(new Date(date.value).getTime() / 1000);
    if (!ts || ts < Date.now() / 1000 + 60) throw new Error("Нужна дата в будущем");
    return String(ts);
  };
  return { nodes: [h("label", {}, "Срок действия"), sel, date], value };
}

route(/^\/add$/, async (ctx) => {
  const d = await loadClients();
  const taken = new Set(d.rows.map((c) => c.name));
  const free = () => { let n = 1; while (taken.has("client" + n)) n++; return "client" + n; };
  const name = h("input", { placeholder: "anna_phone", maxlength: 32, autocapitalize: "off", autocomplete: "off" });
  const exp = expireField();
  let spec = "server";
  const mimLabel = h("div", { class: "muted small" }, "Мимикрия: как у сервера");
  const pro = d.profile === "pro";
  ctx.put(title("➕ Новый клиент"),
    h("label", {}, "Имя — латиница, цифры, _ и -, до 32"),
    h("div", { class: "row" }, name, h("button", { onclick: () => { name.value = free(); } }, "🎲")),
    exp.nodes,
    pro ? h("div", { style: "margin-top:12px" }, mimLabel, h("button", { class: "btn-block", onclick: async () => {
      const box = h("div", { class: "sheet" }, h("h3", {}, "🎭 Мимикрия"));
      let close = null;
      box.append(...await mimicryPicker((s) => { spec = s; mimLabel.textContent = "Мимикрия: " + (s === "server" ? "как у сервера" : s === "none" ? "без I1-I5" : s); close(); }));
      if (ctx.live()) close = sheetOpen(box);
    } }, "🎭 Выбрать мимикрию")) : null,
    enterTo(h("button", { class: "btn-primary btn-block", onclick: (ev) => busy(ev.currentTarget, async () => {
      const v = name.value.trim() || free();
      if (!/^[A-Za-z0-9_-]{1,32}$/.test(v)) throw new Error("Имя: латиница, цифры, _ и -, до 32 символов");
      if (taken.has(v)) throw new Error(`Имя ${v} уже занято`);
      await post("/api/client/add", { name: v, expire: exp.value(), mimicry: spec });
      haptic(); toast("Клиент создан");
      replace(`/client/${encodeURIComponent(v)}/qr`);
    }) }, "Создать"), name));
  if (WEB) name.focus();          // в Telegram клавиатура закрыла бы срок и «Создать», а имя необязательно
});

route(/^\/bulk$/, async (ctx) => {
  let mode = "prefix";
  const tabs = h("div", { class: "chips" });
  const prefix = h("input", { value: "user", maxlength: 27, autocapitalize: "off" });
  const count = h("input", { type: "number", min: 1, max: 200, value: 5 });
  const names = h("textarea", { placeholder: "anna, boris, vera" });
  const box = h("div");
  const exp = expireField();
  const draw = () => {
    tabs.replaceChildren(...[["prefix", "Префикс + номер"], ["names", "Имена списком"]].map(([v, l]) =>
      h("button", { class: "chip" + (mode === v ? " on" : ""), onclick: () => { mode = v; draw(); } }, l)));
    box.replaceChildren(...(mode === "prefix"
      ? [h("label", {}, "Префикс — получатся user-001, user-002…"), prefix, h("label", {}, "Сколько (1-200)"), count]
      : [h("label", {}, "Имена через запятую"), names]));
  };
  draw();
  const make = h("button", { class: "btn-primary btn-block", onclick: (ev) => busy(ev.currentTarget, async () => {
    let spec;
    if (mode === "prefix") {
      const p = prefix.value.trim(), n = Number(count.value);
      if (!/^[A-Za-z0-9_-]{1,27}$/.test(p)) throw new Error("Префикс: латиница, цифры, _ и -, до 27 символов");
      // Только целое: «2.5» awg2 не поймёт
      if (!/^\d{1,3}$/.test(count.value.trim()) || !(n >= 1 && n <= 200)) throw new Error("Количество — целое от 1 до 200");
      spec = `${p}:${n}`;
    } else {
      const list = names.value.split(",").map((s) => s.trim()).filter(Boolean);
      if (!list.length || !list.every((s) => /^[A-Za-z0-9_-]{1,32}$/.test(s))) throw new Error("Имена: латиница, цифры, _ и -, через запятую");
      spec = list.join(",");
    }
    const e = exp.value();
    await runJob(ctx, "Создание клиентов", ["clients", "bulk", spec, ...(e ? [`expire=${e}`] : [])], (created) => {
      const list = Array.isArray(created) ? created : [];
      return [
        h("div", { class: "card" }, h("b", {}, `Создано: ${list.length}`), h("div", { class: "muted small" }, list.join(", "))),
        list.length ? h("button", { class: "btn-primary btn-block", onclick: (ev2) => busy(ev2.currentTarget, async () => {
          await deliver({ what: "zip", names: list }, "Архив конфигов — в чате с ботом");
        }) }, TO("📦 Конфиги архивом в чат", "📦 Скачать конфиги архивом")) : null,
        h("button", { class: "btn-block", onclick: () => replace("/clients") }, "👥 К списку"),
      ];
    }, { onBack: back });
  }) }, "Создать");
  ctx.put(title("➕ Несколько клиентов"), tabs, box, exp.nodes, enterTo(make, prefix, count, names));
});

// ── Сервер ────────────────────────────────────────────────
const PROFILES = { lite: "AmneziaVPN", pro: "Мощный", standard: "Standard" };
const DNS = [["Cloudflare", "1.1.1.1, 1.0.0.1"], ["Google", "8.8.8.8, 8.8.4.4"],
  ["Quad9", "9.9.9.9, 149.112.112.112"], ["Яндекс", "77.88.8.8, 77.88.8.1"]];

route(/^\/server$/, async (ctx) => {
  const r = await callR(["server", "info"]);
  // Подсказка о переходе на 3.1 — не предупреждение: сервер на 2.0 — обычный выбор,
  // а переход — в «Протоколе»; в карточке — только то, что правда требует внимания
  const d = r.data || {};
  const warnings = [d.reboot].filter(Boolean);
  const state = !d.exists ? "" : d.up ? "on" : "bad";
  ctx.put(title("Сервер"),
    warnings.length ? h("div", { class: "card warn small" }, warnings.map((w) => h("div", { class: "row", style: "padding:2px 0" },
      icon("triangle-alert"), w))) : null,
    d.exists ? ecard({ state, name: "awg0", attrs: { "data-name": "awg0" },
      right: pill(d.up ? "поднят" : "не поднят", d.up ? "ok" : "bad"),
      meta: [tag("AWG " + (d.proto || "?"), "accent"), tag(d.profile_label || PROFILES[d.profile] || d.profile || ""),
        tag("MTU " + d.mtu), tag(d.region === "ru" ? "Россия" : "мир", "", "globe")],
      lines: [h("span", { onclick: (ev) => { ev.stopPropagation(); copy(d.endpoint); }, style: "cursor:pointer" }, d.endpoint || "", " ", icon("copy"))],
      acts: [act("refresh-cw", "Рестарт", (b) => quickAsk(b, AWG0_RESTART, "awg0 перезапущен", ["server", "restart"])),
        act("shuffle", "Протокол", () => go("/server/proto")), act("globe", "Endpoint", () => go("/server/endpoint"))] })
      : ecard({ name: "Сервер не создан", right: pill(d.installed ? "компоненты есть" : "нет компонентов", d.installed ? "ok" : "warn"),
        lines: ["Создай сервер — те же вопросы, что в меню awg2"] }),
    d.exists ? statGrid([
      [String(d.clients || 0), "Клиентов", "конфигов на сервере", () => go("/clients")],
      [String(d.port), "UDP-порт", d.domain ? "домен " + d.domain : "IP в конфигах"],
      [d.net || "—", "Подсеть", "адреса клиентов"],
      [(d.mimicry || "none"), "Мимикрия", d.mimicry_domain || (d.mimicry && d.mimicry !== "none" ? "пакеты I1-I5" : "без I1-I5")],
    ]) : null,
    !d.exists ? btn("✨ Создать сервер", () => go("/server/create"), "btn-block" + (d.installed ? " btn-primary" : "")) : null,
    h("h2", {}, "Обслуживание"),
    h("div", { class: "card list" },
      d.exists ? menuItem("🎛 Параметры AWG", "Jc, S1-S4, H1-H4 вручную", () => go("/server/params")) : null,
      menuItem("🧩 Модуль ядра", "версии, обновление, откат", () => go("/server/module")),
      menuItem("🛡 Антисканер", "сети сканеров РКН и госорганов — не до портов сервера", () => go("/server/antiscan")),
      menuItem(d.installed ? "📦 Компоненты" : "📦 Установить компоненты", "пакеты, модуль, amneziawg-tools",
        () => jobAsk(ctx, "Пакеты, заголовки ядра, сборка модуля AmneziaWG и amneziawg-tools из исходников. Обычно 5-15 минут. "
          + "Если ядру нет заголовков, поставится свежее ядро — тогда понадобится перезагрузка.", "Установка компонентов", ["server", "install"])),
      menuItem("🛠 Починить", "конфиги, правила, службы", () => runJob(ctx, "Проверка и ремонт", ["server", "repair"],
        (res) => (res ? h("div", { class: "card" }, kv("Найдено проблем", res.issues || 0), kv("Исправлено", res.fixed || 0)) : null))),
      menuItem("♻️ Перезагрузка", "панель и бот вернутся сами", () => quickAsk(null,
        "Перезагрузить сервер? Панель и бот вернутся сами через минуту-две.", "Сервер перезагружается", ["server", "reboot"], () => {}))),
    d.exists ? h("button", { class: "btn-danger btn-block", onclick: (ev) => quickAsk(ev.currentTarget,
      "Сброс сервера: awg0 и все клиенты будут удалены, туннели выключены. Перед сбросом делается авто-бэкап, "
      + "компоненты остаются. Сбросить?", "Сервер сброшен", ["server", "reset"]) }, "⚠️ Сбросить сервер") : null);
});

// Антисканер: новые подключения из сетей сканеров РКН, СКИПА и госорганов
// отбрасываются до служб сервера. Списки качает и проверяет awg2
const num = (n) => String(Math.round(+n || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, " ");
route(/^\/server\/antiscan$/, async (ctx) => {
  const d = (await call("antiscan", "status")) || {};
  const on = !!d.enabled, lists = d.lists || [], allow = d.allow || [], top = d.top || [];
  const ip = h("input", { placeholder: "1.2.3.4 или 1.2.3.0/24", autocapitalize: "off", autocomplete: "off",
    "aria-label": "Адрес или подсеть", style: "flex:1;min-width:0" });
  function setList(b, id) {
    const want = lists.filter((x) => !!x.on !== (x.id === id)).map((x) => x.id);
    if (!want.length) return fail(new Error("Нужен хотя бы один список"));
    return quick(b, "Списки применены", ["antiscan", "lists", want.join(",")]);
  }
  const add = btn("➕ Добавить", (b) => {
    const v = ip.value.trim();
    if (!/^[0-9A-Fa-f.:]+(\/\d{1,3})?$/.test(v)) return fail(new Error("Нужен IPv4 или IPv6 адрес, можно с маской"));
    return quick(b, "Исключение добавлено", ["antiscan", "allow", "add", v]);
  });
  add.style.flex = "none"; add.style.whiteSpace = "nowrap";
  ctx.put(title("🛡 Антисканер"),
    hint("Новые подключения из сетей сканеров РКН и госорганов отбрасываются до SSH, Xray и панелей. "
      + "VPN-трафик клиентов не трогается."),
    h("div", { class: "card" },
      kv("Статус", !on ? h("span", { class: "muted" }, "○ выключен") : d.active ? h("span", { class: "ok" }, "● включён")
        : h("span", { class: "warn" }, "▲ правило не на месте")),
      on ? kv("Подсетей", num((d.v4 || 0) + (d.v6 || 0))) : null,
      on ? kv("Отбито", num(d.dropped) + " подключений") : null,
      d.updated ? kv("Списки", fmtTime(d.updated)) : null,
      d.error ? h("div", { class: "small warn" }, "▲ " + d.error) : null),
    h("div", { class: "actions", style: "margin-top:8px" },
      on ? btn("⏹ Выключить", (b) => quickAsk(b, "Выключить антисканер? Правило и наборы снимаются, сканеры снова "
        + "увидят порты сервера.", "Антисканер выключен", ["antiscan", "off"]))
        : btn("✅ Включить", (b) => quickAsk(b, "Включить антисканер? Новые подключения из сетей списков не пройдут — "
          + "в том числе клиенты VPN и, возможно, ты сам с другого адреса. Твой текущий адрес и SSH — в исключения сами. "
          + "Выключить можно здесь или в боте.", "Антисканер включён", ["antiscan", "on"]), "btn-primary"),
      on ? btn("🔄 Обновить списки", (b) => quick(b, "Списки обновлены", ["antiscan", "update"])) : null,
      btn("📜 Журнал", () => go("/log/antiscan"))),
    top.length ? [h("h2", {}, "Чаще всего стучались"), h("div", { class: "card" }, top.map((t) =>
      h("div", { style: "padding:5px 0" }, h("div", {}, h("b", {}, num(t.packets)), " · ", t.net),
        t.org ? h("div", { class: "muted small" }, t.org) : null)))] : null,
    h("h2", {}, "Списки"),
    h("div", { class: "card list" }, lists.map((x) => h("div", { class: "item", onclick: (ev) => setList(ev.currentTarget, x.id) },
      h("div", { class: "check" + (x.on ? " on" : "") }, x.on ? icon("check") : null),
      h("div", { class: "main" }, h("div", { class: "title" }, x.name),
        h("div", { class: "sub" }, x.entries ? num(x.entries) + " подсетей" : "скачается при включении"))))),
    h("h2", {}, "Исключения"),
    hint("Адрес или подсеть из исключений не блокируется. Адреса сервера и открытых SSH-сессий — в исключениях всегда."
      + (d.ssh && d.ssh.length ? " Твой SSH: " + d.ssh.join(", ") + "." : "")),
    allow.length ? h("div", { class: "card list" }, allow.map((a) => h("div", { class: "item", onclick: (ev) =>
      quickAsk(ev.currentTarget, `Убрать исключение ${a}?`, "Исключение убрано", ["antiscan", "allow", "del", a]) },
    h("div", { class: "main" }, h("div", { class: "title mono wrap" }, a)), h("div", { class: "side bad" }, icon("x"))))) : null,
    h("div", { class: "row", style: "gap:8px;margin-top:8px" }, ip, enterTo(add, ip)),
    hint("Клиенты VPN, которые подключаются из этих сетей, тоже не подключатся — для них есть исключения."));
});

// Создание сервера — те же вопросы, что задают меню awg2 и бот, одной формой
route(/^\/server\/create$/, async (ctx) => {
  const [info, profiles] = await Promise.all([call("server", "info"), call("mimicry")]);
  if (info.exists) {
    return ctx.put(h("div", { class: "empty" }, "Сервер уже создан"),
      h("button", { class: "btn-block", onclick: () => replace("/server") }, "🖥 К серверу"));
  }
  // Без компонентов форма упёрлась бы в «не установлены» — сначала они; «Назад» после задачи вернёт сюда же
  if (!info.installed) {
    return ctx.put(title("Создание сервера"),
      h("div", { class: "card" }, "Сначала нужны компоненты: пакеты, заголовки ядра, модуль AmneziaWG и amneziawg-tools — "
        + "сборка из исходников, обычно 5-15 минут. Когда закончится — вернёшься к созданию сервера."),
      btn("📦 Установить компоненты", () => runJob(ctx, "Установка компонентов", ["server", "install"]), "btn-block btn-primary"));
  }
  const why31 = { tools: "▲ amneziawg-tools не умеют 3.1 — обнови модуль и tools (5-10 минут), затем вернёшься сюда",
    module: "▲ Модуль ядра собран без 3.1 — обнови модуль и tools (5-10 минут), затем вернёшься сюда" }[info.proto31_why]
    || "▲ 3.1 не прошла проверку на сервере" + (info.reboot ? ": " + info.reboot : " — Сервер → Модуль ядра");
  const mims = profiles || [];
  const f = { region: "world", profile: "lite", lite: "none", level: "3", proto: info.proto31 ? "3.1" : "2.0" };
  const box = h("div");
  const chips = (key, opts) => h("div", { class: "chips" }, opts.map(([v, l]) =>
    h("button", { class: "chip" + (f[key] === v ? " on" : ""), onclick: () => { f[key] = v; draw(); } }, l)));
  const mimSel = h("select", { onchange: () => draw() }, mims.map((p) => h("option", { value: p.id }, p.label)));
  if (mims.some((p) => p.id === "dns")) mimSel.value = "dns";
  const dnsSel = h("select", { onchange: () => draw() }, DNS.map(([l, ips], i) => h("option", { value: i }, `${l} — ${ips}`)),
    h("option", { value: "manual" }, "Вручную…"));
  const dnsIn = h("input", { placeholder: "1.1.1.1, 8.8.8.8", inputmode: "decimal" });
  const mtu = h("input", { type: "number", min: 1280, max: 1500 });
  const net = h("input", { placeholder: "случайная 10.x.y.0/24", autocapitalize: "off", autocomplete: "off" });
  const port = h("input", { type: "number", min: 1024, max: 65535, placeholder: "случайный" });
  const ep = h("input", { placeholder: "vpn.example.com", autocapitalize: "off", autocomplete: "off" });
  const first = h("input", { placeholder: "случайное", maxlength: 32, autocapitalize: "off", autocomplete: "off" });

  function draw() {
    const pro = f.profile === "pro", rec = pro ? "1320" : "1280";
    const mim = mims.find((p) => p.id === mimSel.value);
    mtu.placeholder = rec;
    box.replaceChildren(...[
      h("label", {}, "Где стоит сервер — от этого зависят домены мимикрии"),
      chips("region", [["world", "🌍 Мир / Европа"], ["ru", "🇷🇺 Россия"]]),
      h("label", {}, "Профиль"),
      chips("profile", [["lite", "AmneziaVPN"], ["pro", "Мощный"]]),
      hint(pro ? "Широкие диапазоны и I1-I5 — сильнее против DPI"
        : "Как официальный клиент: MTU 1280, без I1-I5 (рекомендуется)"),
      h("label", {}, "Мимикрия"),
      pro ? chips("level", [["3", "Цепочка I1-I5"], ["2", "Только I1"], ["none", "Без I1-I5"]])
        : chips("lite", [["none", "Без I1-I5"], ["dns:2", "Пакет I1 (DNS)"]]),
      pro && f.level !== "none" ? [mimSel, mim ? hint(mim.hint) : null] : null,
      hint(pro ? "Цепочка — полная; только I1 — для Keenetic; без I1-I5 — для WireSock"
        : "У официального клиента AmneziaVPN строк I нет; пакет I1 — один компактный DNS-запрос"),
      h("label", {}, "Версия протокола — на весь сервер"),
      chips("proto", info.proto31 ? [["3.1", "AWG 3.1"], ["2.0", "AWG 2.0"]] : [["2.0", "AWG 2.0"]]),
      hint(info.proto31 ? "3.1 — быстрее, заголовки под шифром; клиентам нужен AmneziaVPN 5.0.1.5+ или AmneziaWG с 3.1. "
        + "2.0 — подключится любой клиент AmneziaWG" : why31),
      !info.proto31 && ["tools", "module"].includes(info.proto31_why)
        ? btn("⬆️ Обновить модуль и tools", () => jobAsk(ctx, "Собрать и поставить последние модуль ядра и amneziawg-tools? "
          + "Обычно 5-10 минут; модуль перезагрузится.", "Обновление модуля и tools", ["module", "all"]), "btn-block") : null,
      h("label", {}, "DNS для клиентов"), dnsSel, dnsSel.value === "manual" ? dnsIn : null,
      h("label", {}, `MTU — рекомендуется ${rec}`), mtu,
      h("label", {}, "Подсеть клиентов"), net,
      hint("Случайная — меньше шансов совпасть с домашней сетью клиента"),
      h("label", {}, "UDP-порт"), port,
      h("label", {}, "Домен для конфигов (необязательно)"), ep,
      hint("С доменом сервер можно перенести без перевыдачи конфигов. A-запись должна указывать сюда"),
      h("label", {}, "Имя первого клиента"), first,
    ].flat(Infinity).filter((n) => n != null));
  }
  draw();

  function args() {
    const pro = f.profile === "pro", a = [`profile=${f.profile}`, `proto=${f.proto}`, `region=${f.region}`];
    let dns = dnsSel.value === "manual" ? dnsIn.value : DNS[+dnsSel.value][1];
    const ips = dns.split(",").map((x) => x.trim()).filter(Boolean);
    if (!ips.length || !ips.every(validIp)) throw new Error("DNS: IPv4-адреса через запятую");
    dns = ips.join(", ");
    const m = mtu.value.trim() || (pro ? "1320" : "1280");
    if (!/^\d+$/.test(m) || +m < 1280 || +m > 1500) throw new Error("MTU — число 1280-1500");
    const mimicry = !pro ? f.lite : f.level === "none" ? "none" : `${mimSel.value}:${f.level}`;
    a.push(`dns=${dns}`, `mtu=${m}`, `mimicry=${mimicry}`);
    const n = net.value.trim();
    if (n) {
      const g = n.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}\/24$/);
      if (!g || g.slice(1).some((x) => +x > 255)) throw new Error("Подсеть — сеть /24, например 10.8.0.0/24");
      a.push(`net=${g[1]}.${g[2]}.${g[3]}.0/24`);
    }
    const p = port.value.trim();
    if (p) {
      if (!validPort(p, 1024)) throw new Error("Порт — число 1024-65535");
      a.push(`port=${p}`);
    }
    const e = ep.value.trim().toLowerCase();
    if (e) {
      if (!DOMAIN_RE.test(e)) throw new Error("Домен — имя вида vpn.example.com");
      a.push(`endpoint=${e}`);
    }
    const c = first.value.trim();
    if (c) {
      if (!/^[A-Za-z0-9_-]{1,32}$/.test(c)) throw new Error("Имя клиента: латиница, цифры, _ и -, до 32");
      a.push(`client=${c}`);
    }
    return a;
  }
  const createBtn = h("button", { class: "btn-primary btn-block", onclick: (ev) => busy(ev.currentTarget, async () => {
    const a = args();
    await runJob(ctx, "Создание сервера", ["server", "create", ...a], (res) => {
      const name = res && res.client;
      return name ? [
        h("div", { class: "card" }, kv("Первый клиент", name)),
        h("button", { class: "btn-primary btn-block", onclick: () => replace(`/client/${encodeURIComponent(name)}/qr`) }, "📄 Конфиг и QR"),
        confBtns(name, false),
      ] : null;
    // Не вышло — «Назад» к той же форме с введёнными полями, а не к пустой
    }, { onBack: (ok) => (ok ? replace("/server") : showForm()) });
  }) }, "✨ Создать сервер");
  const showForm = () => { ctx.put(title("✨ Создание сервера"), box, createBtn); window.scrollTo(0, 0); };
  showForm();
});

route(/^\/server\/proto$/, async (ctx) => {
  const d = (await call("server", "info")) || {};
  const cur = d.proto || "2.0", n = d.clients || 0;
  const doIt = async (target) => {
    if (!await confirmTg(`Перегенерировать параметры на AWG ${target}? Все клиенты потеряют связь до получения нового конфига.`)) return;
    await runJob(ctx, `Переход на AWG ${target}`, ["server", "proto", target], () => [
      h("button", { class: "btn-primary btn-block", onclick: (ev) => busy(ev.currentTarget, async () => {
        await deliver({ what: "export" }, "Архив всех конфигов — в чате с ботом");
      }) }, TO("📦 Все конфиги архивом в чат", "📦 Скачать все конфиги архивом")),
      h("button", { class: "btn-block", onclick: () => go("/clients") }, "👥 Клиенты"),
    ], { onBack: () => replace("/server") });
  };
  ctx.put(title("🔀 Протокол"),
    h("div", { class: "card" }, kv("Сейчас", `AWG ${cur}`), kv("Клиентов", n)),
    h("div", { class: "card small" },
      h("div", {}, "• 3.1 — быстрее, заголовки под шифром; 2.0 — для старых клиентов"),
      h("div", {}, "• 🔁 — новые параметры той же версии"),
      h("div", { class: "muted", style: "margin-top:6px" }, "Ключи, адреса, имена и сроки сохраняются. Все клиенты получают "
        + "новые конфиги и до их замены не подключатся."),
      d.proto31 ? null : h("div", { class: "warn", style: "margin-top:6px" }, "▲ Модуль не умеет 3.1 — при переходе он обновится (долго)")),
    btn(cur === "3.1" ? "🔁 Новые параметры 3.1" : "⬆️ Перейти на 3.1", () => doIt("3.1"), "btn-primary btn-block"),
    btn(cur === "2.0" ? "🔁 Новые параметры 2.0" : "⬇️ Вернуть 2.0", () => doIt("2.0"), "btn-block"),
    btn("🎛 Изменить параметры вручную", () => go("/server/params"), "btn-block"));
});

// Параметры AWG вручную: поля с текущими значениями, проверка в awg2 на лету
// (server params check), запись одним вызовом (server params set force)
const PARAM_GROUPS = [
  ["Мусорные пакеты", 3, [["Jc", "Jc", "сколько"], ["Jmin", "Jmin", "байт"], ["Jmax", "Jmax", "байт"]]],
  ["Паддинг", 4, [["S1", "S1", "запрос"], ["S2", "S2", "ответ"], ["S3", "S3", "cookie"], ["S4", "S4", "данные"]]],
  ["Заголовки", 1, [["H1", "H1", "запрос"], ["H2", "H2", "ответ"], ["H3", "H3", "cookie"], ["H4", "H4", "данные"]]],
  ["AWG 3.x", 2, [["ContentPaddingAddition", "Паддинг данных", "байт, a-b"], ["RekeyAfterTime", "RekeyAfter", "с"],
    ["RekeyTimeout", "RekeyTimeout", "с"], ["RejectAfterTime", "RejectAfter", "с"], ["KeepaliveTimeout", "Keepalive", "с"],
    ["MaxHandshakeAttempts", "MaxHandshake", "попыток"]]],
];
const PARAM_SWITCHES = [["RandomTrailers", "RandomTrailers", "хвосты случайной длины — обязаны совпадать у клиентов"],
  ["DisableCookies", "DisableCookies", "сервер не отвечает cookie под нагрузкой — только на сервере"]];

route(/^\/server\/params$/, async (ctx) => {
  const d = await call("server", "params");
  const orig = d.values || {}, cur = Object.assign({}, orig), inputs = {};
  const msgs = h("div"), applyBtn = h("button", { class: "btn-primary", disabled: true }, "✅ Применить");
  const edits = () => Object.keys(orig).filter((k) => cur[k] !== orig[k]).map((k) => `${k}=${cur[k]}`);
  let seq = 0, timer = null, last = null;
  async function check() {
    const my = ++seq;
    const r = await call("server", "params", "check", ...edits()).catch((e) => ({ errors: [e.message] }));
    if (my !== seq || !ctx.live()) return;
    last = r;
    const changed = new Set(r.changed || []);
    for (const [k, inp] of Object.entries(inputs)) inp.classList.toggle("chg", changed.has(k));
    msgs.replaceChildren(...[
      (r.errors || []).length ? h("div", { class: "card bad small" }, r.errors.map((e) => h("div", {}, "❌ " + e))) : null,
      (r.warnings || []).length ? h("div", { class: "card warn small" }, r.warnings.map((w) => h("div", {}, "▲ " + w))) : null,
    ].filter(Boolean));
    applyBtn.disabled = !changed.size || (r.errors || []).length > 0;
  }
  const recheck = () => { clearTimeout(timer); timer = setTimeout(() => busy(null, check), 350); };
  const field = ([k, label, sub]) => {
    const inp = inputs[k] = h("input", { value: orig[k] || "", autocomplete: "off", autocapitalize: "off", spellcheck: "false",
      inputmode: /^(Jc|Jmin|Jmax|S\d)$/.test(k) ? "numeric" : null, "data-key": k,
      oninput: () => { cur[k] = inp.value.replace(/\s+/g, ""); recheck(); } });
    return h("div", { class: "pf" }, h("label", {}, h("b", {}, label), " ", h("span", {}, sub)), inp);
  };
  applyBtn.onclick = () => busy(applyBtn, async () => {
    await check();
    const r = last || {};
    if ((r.errors || []).length || !(r.changed || []).length) return;
    const breaking = r.breaking || [];
    // Главное — сразу после списка: длинный текст в Telegram режется с середины (предупреждения)
    const text = [`Меняются: ${r.changed.join(", ")}.`,
      breaking.length ? `${breaking.join(", ")} обязаны совпадать у клиентов: все клиенты (${d.clients || 0}) потеряют связь `
        + "до получения нового конфига." : "Старые конфиги продолжат работать.",
      ...(r.warnings || []).map((w) => "▲ " + w),
      "Перед записью — авто-бэкап; не поднимется awg0 — вернутся прежние. Применить?"].join("\n");
    if (!await confirmTg(text)) return;
    const res = await callR(["server", "params", "set", "force", ...edits()]);
    haptic(); toast("✅ Параметры AWG обновлены", 3000);
    if ((res.data || {}).breaking && res.data.breaking.length && d.clients) {
      const pick = await sheet("Клиентам нужны новые конфиги", [{ label: TO("📦 Все конфиги архивом в чат", "📦 Скачать все конфиги архивом"), value: "zip" },
        { label: "👥 К клиентам", value: "cl" }]);
      if (pick === "zip") await busy(null, () => deliver({ what: "export" }, "Архив всех конфигов — в чате с ботом"));
      if (pick === "cl") return go("/clients");
    }
    render();
  });
  const is3 = String(d.proto || "").startsWith("3");
  ctx.put(title("🎛 Параметры AWG", pill("AWG " + (d.proto || "?"), "accent")),
    h("div", { class: "card small muted" }, "S и H обязаны совпадать у сервера и клиентов — после их правки старые конфиги "
      + "не подключатся. Jc/Jmin/Jmax" + (is3 ? ", паддинг данных и таймеры" : "") + " — не обязаны."),
    PARAM_GROUPS.filter(([, , keys]) => keys.some(([k]) => k in orig)).map(([name, cols, keys]) => [h("h2", {}, name),
      h("div", { class: "pgrid", style: `--c:${cols}` }, keys.filter(([k]) => k in orig).map(field))]),
    PARAM_SWITCHES.filter(([k]) => k in orig).map(([k, label, sub]) => switchRow(label, sub, orig[k] === "on", async (on) => {
      cur[k] = on ? "on" : "off"; recheck();
    })),
    msgs,
    h("div", { class: "bar" }, h("button", { onclick: () => render() }, "↩️ Сбросить"), applyBtn));
});

route(/^\/server\/endpoint$/, async (ctx) => {
  const d = (await call("server", "info")) || {};
  let all = true;
  const dom = h("input", { value: d.domain || "", placeholder: "vpn.example.com", autocapitalize: "off", autocomplete: "off" });
  const save = (b, value) => quick(b, "Endpoint изменён", ["server", "endpoint", value, ...(all ? [] : ["keep"])], () => back());
  ctx.put(title("🌍 Endpoint"),
    h("div", { class: "card" }, kv("В конфигах", d.endpoint || ""),
      h("div", { class: "muted small" }, d.domain ? "Домен задан — сервер можно переносить без перевыдачи конфигов."
        : "Сейчас IP. С доменом переезд сервера не требует новых конфигов.")),
    h("label", {}, "Домен — A-запись должна указывать на этот сервер"), dom,
    switchRow("Переписать в выданных конфигах", "иначе — только для новых клиентов", all, (on) => { all = on; }),
    btn("💾 Сохранить домен", (b) => {
      const v = dom.value.trim().toLowerCase();
      if (!DOMAIN_RE.test(v)) return fail(new Error("Нужно имя вида vpn.example.com"));
      return save(b, v);
    }, "btn-primary btn-block"),
    d.domain ? btn("🔢 Вернуть публичный IP", (b) => save(b, "ip"), "btn-block") : null);
});

route(/^\/server\/module$/, async (ctx) => {
  const r = await callR(["module", "report"]);
  const d = r.data || {};
  const upd = (v) => (v ? h("span", { class: "ok" }, " · ⬆️ есть " + v) : null);
  async function pickTag(b) {
    const tags = await busy(b, () => call("module", "tags"));
    if (!tags) return;
    const tag = await sheet("📋 Версия модуля — сверху новые", tags.map((t) => ({ label: t, value: t })));
    if (tag) await jobAsk(ctx, `Собрать и поставить модуль ${tag}?`, `Модуль ${tag}`, ["module", "update", tag, "force"]);
  }
  async function rollback(b) {
    const rows = await busy(b, () => call("module", "backups"));
    if (!rows) return;
    const path = await sheet("⏪ Копии исходников — сверху новые", rows.map((x) => ({ label: `${fmtTime(x.time)} · ${x.name}`, value: x.path })));
    if (path) await jobAsk(ctx, `Вернуть модуль из ${path.split("/").pop()}?`, "Откат модуля", ["module", "rollback", path]);
  }
  ctx.put(title("🧩 Модуль ядра"),
    d.reboot || d.secure_boot ? h("div", { class: "card warn small" }, d.reboot ? h("div", {}, "▲ " + d.reboot) : null,
      d.secure_boot ? h("div", {}, "▲ Secure Boot включён — неподписанный модуль ядро не загрузит") : null) : null,
    h("div", { class: "card" },
      kv("Ядро", d.kernel || ""),
      kv("Установлены", (d.kernels || []).join(", ") || "—"),
      kv("Модуль", h("span", {}, d.module || "не установлен", " ", d.loaded ? h("span", { class: "ok" }, "● загружен")
        : h("span", { class: "bad" }, "● не загружен"), upd(d.module_update))),
      kv("tools", h("span", {}, d.tools || "не установлены", upd(d.tools_update)))),
    h("div", { class: "actions" },
      btn("⬆️ Модуль", () => jobAsk(ctx, "Собрать и поставить последнюю версию модуля? Туннели лягут на несколько секунд "
        + "при перезагрузке модуля.", "Обновление модуля", ["module", "update"]), d.module_update ? "btn-primary" : null),
      btn("⬆️ Tools", () => runJob(ctx, "Обновление amneziawg-tools", ["module", "tools"]), d.tools_update ? "btn-primary" : null),
      btn("📋 Версия модуля", pickTag),
      btn("🔁 Перезагрузить", () => jobAsk(ctx, "Перезагрузить модуль? Туннели лягут на несколько секунд, клиенты "
        + "переподключатся сами.", "Перезагрузка модуля", ["module", "reload"])),
      btn("🧱 Под все ядра", () => jobAsk(ctx, "Собрать модуль под все установленные ядра? Несколько минут: заголовки ядер и сборка DKMS.",
        "Сборка модуля под все ядра", ["module", "rebuild"])),
      d.backups ? btn("⏪ Откат", rollback) : null,
      btn("🔎 Проверить", (b) => quick(b, "Версии проверены", ["module", "check"])),
      btn("📜 Журнал сборки", () => go("/log/module"))),
    hint("«Модуль» и «Tools» — до последней версии · «Перезагрузить» — модуль без ребута · «Под все ядра» — собрать под все установленные"),
    h("details", { class: "card" }, h("summary", {}, "Полный отчёт"), h("pre", {}, plainLog(r.log))));
});

// ── Туннели и DNS ─────────────────────────────────────────
const STATE_WORD = { up: "включён", off: "выключен", none: "не настроен" };
const TUNNELS = [["warp", "☁️", "WARP", "Cloudflare"], ["xray", "🛰", "Xray", "VLESS, VMess, Trojan, SS"],
  ["tun2socks", "🧦", "tun2socks", "внешний SOCKS5"], ["exits", "🚪", "Exit-ноды WG", "другие AWG/WG-серверы"]];
const TUNNEL_ICON = { warp: "cloud", xray: "satellite", tun2socks: "waypoints", exits: "door-open" };
const tunnelDown = (t) => `Выключить ${t}? Клиенты, идущие через него, пойдут напрямую через сервер; настройки сохранятся.`;
route(/^\/tunnels$/, async (ctx) => {
  const d = (await call("tunnels", "status")) || {};
  const n = d.cascade || 0;
  const card = (path, name, st, meta, line) => ecard({ state: st === "up" ? "on" : st === "off" ? "warn" : "", name,
    onopen: () => go(path), attrs: { "data-name": name },
    right: pill(STATE_WORD[st] || st || "—", st === "up" ? "ok" : st === "off" ? "warn" : ""), meta, lines: [line] });
  const configured = TUNNELS.filter(([k]) => d[k] && d[k] !== "none").length;
  const active = TUNNELS.filter(([k]) => d[k] === "up").map(([, , name]) => name).join(", ");
  ctx.put(title("Туннели и DNS"),
    statGrid([
      [active || "напрямую", "Выход клиентов", "один туннель за раз"],
      [`${configured}/${TUNNELS.length}`, "Настроено", `каскад ${n} · DNS ${STATE_WORD[d.dns] || "—"}`],
    ]),
    h("h2", {}, "Выход клиентов"),
    TUNNELS.map(([k, , name, sub]) => card("/tunnels/" + k, name, d[k], [tag(sub, "", TUNNEL_ICON[k])], null)),
    h("h2", {}, "Ещё"),
    card("/tunnels/cascade", "Каскад портов", n ? "up" : "none", [tag(n ? `правил: ${n}` : "правил нет", n ? "accent" : "", "shuffle")],
      "порт этого сервера → другой сервер"),
    card("/tunnels/dns", "Шифрованный DNS", d.dns, [tag("DoH", "", "lock-keyhole"), tag("dnscrypt-proxy")], "DNS клиентов — через DoH, DoT закрыт"),
    h("button", { class: "btn-danger btn-block", onclick: (ev) => quickAsk(ev.currentTarget, "Выключить все туннели (WARP, Xray, "
      + "tun2socks, exit-ноды)? Клиенты пойдут напрямую через сервер, настройки сохранятся.", "Туннели выключены",
    ["tunnels", "panic"]) }, "🚨 Всё напрямую"),
    hint("Аварийно выключить туннели — если клиенты остались без интернета"));
});

// Кто из клиентов идёт через туннель (WARP, Xray)
route(/^\/tunnels\/(warp|xray)\/clients$/, async (ctx, kind) => {
  const t = kind === "warp" ? "WARP" : "Xray";
  const rows = (await call("tunnels", "clients", kind)) || [];
  const list = h("div", { class: "card list" });
  // Строка на время запроса не нажимается (двойной тап — один запрос), итог —
  // то, что отправили, а не «наоборот от того, что было»
  const flip = (c, row) => {
    if (c.busy) return;
    const next = !c.on;
    c.busy = true; row.classList.add("reloading");
    busy(null, async () => {
      await call("tunnels", "client", kind, c.name, next ? "on" : "off");
      c.on = next; haptic();
    }).then(() => { c.busy = false; draw(); });
  };
  const draw = () => list.replaceChildren(...(rows.length ? rows.map((c) => {
    const row = h("div", { class: "item" + (c.busy ? " reloading" : ""), "data-name": c.name, onclick: () => flip(c, row) },
      h("div", { class: "main" }, h("div", { class: "title" }, c.name), h("div", { class: "sub" }, `${c.ip} · ${c.on ? "через " + t : "напрямую"}`)),
      h("div", { class: "switch" + (c.on ? " on" : "") }));
    return row;
  }) : [h("div", { class: "empty" }, "Клиентов нет")]));
  draw();
  ctx.put(title(`👥 Клиенты в ${t}`), hint(`Включено — клиент выходит через ${t}, выключено — напрямую через сервер.`), list,
    rows.length ? h("div", { class: "bar" },
      btn("✅ Все через " + t, (b) => quick(b, "Все через " + t, ["tunnels", "client", kind, "all"])),
      btn("➖ Все напрямую", (b) => quick(b, "Все напрямую", ["tunnels", "client", kind, "none"]))) : null);
});

// WARP
route(/^\/tunnels\/warp$/, async (ctx) => {
  const r = await callR(["warp", "status"]);
  const d = r.data || {}, wg = d.backend === "wg", conf = d.configured;
  async function backend(b) {
    const opts = [["wg", "wg — WireGuard ядра, быстрее", d.wg_possible], ["usque", "usque — MASQUE (HTTP/3), когда WireGuard к Cloudflare режут", d.usque_possible]]
      .filter(([v, , ok]) => v !== d.backend && ok).map(([v, label]) => ({ label, value: v }));
    if (!opts.length) return toast("Другой бэкенд здесь недоступен");
    const v = await sheet(`🔀 Бэкенд WARP — сейчас ${d.backend || "?"}`, opts);
    if (v) await runJob(ctx, `WARP: бэкенд ${v}`, ["warp", "backend", v]);
  }
  ctx.put(title("☁️ WARP"), logCard(r.log),
    conf ? switchRow("🩺 Health-check", "сам перезапускает WARP, если тот перестал отвечать", d.health,
      (on) => call("warp", "health", on ? "on" : "off")) : null,
    h("div", { class: "actions" },
      conf && !d.up ? btn("▶️ Включить", () => runJob(ctx, "Включение WARP", ["warp", "up"]), "btn-primary") : null,
      d.up ? btn("⏹ Выключить", (b) => quickAsk(b, tunnelDown("WARP"), "WARP выключен", ["warp", "down"])) : null,
      conf ? btn("👥 Клиенты", () => go("/tunnels/warp/clients")) : null,
      btn(conf ? "📦 Переустановить" : "📦 Установить", () => runJob(ctx, conf ? "Переустановка WARP" : "Установка WARP", ["warp", "install"]),
        conf ? null : "btn-primary"),
      wg && conf ? btn("🔑 Ключ Warp+", () => go("/tunnels/warp/key")) : null,
      wg ? btn("📥 Импорт", () => go("/tunnels/warp/import")) : null,
      wg && conf ? btn("🔎 Поиск endpoint", () => go("/tunnels/warp/endpoint")) : null,
      btn("🔀 Бэкенд", backend),
      btn("📜 Журнал", () => go(d.backend === "usque" ? "/log/usque" : "/log/warp")),
      conf ? btn("🗑 Удалить", (b) => quickAsk(b, "Удалить WARP: аккаунт, профиль, службы?", "WARP удалён", ["warp", "remove"]), "btn-danger") : null),
    hint(`«${conf ? "Переустановить" : "Установить"}» — зарегистрироваться в Cloudflare заново (бэкенд ${d.backend || "?"})`
      + (wg ? " · «Импорт» — свой wgcf-profile.conf, если регистрация отсюда не проходит" : "")));
});

route(/^\/tunnels\/warp\/key$/, async (ctx) => {
  const key = h("input", { placeholder: "xxxxxxxx-xxxxxxxx-xxxxxxxx", autocapitalize: "off", autocomplete: "off" });
  ctx.put(title("🔑 Ключ Warp+"), h("label", {}, "В приложении 1.1.1.1: Аккаунт → Ключ"), key,
    btn("Сохранить", (b) => {
      const v = key.value.trim();
      if (!/^[A-Za-z0-9]+-[A-Za-z0-9]+-[A-Za-z0-9]+$/.test(v)) return fail(new Error("Неверный формат ключа"));
      return quick(b, "Ключ Warp+ применён", ["warp", "license", v], () => back());
    }, "btn-primary btn-block"));
});

route(/^\/tunnels\/warp\/import$/, async (ctx) => {
  const ta = h("textarea", { placeholder: "[Interface]\nPrivateKey = …\n\n[Peer]\n…", style: "min-height:160px" });
  ctx.put(title("📥 Профиль WARP"),
    h("div", { class: "card small" }, "Зарегистрируй профиль там, где Cloudflare доступен (например, shell.cloud.google.com):",
      h("pre", { style: "margin:8px 0 0" }, "./wgcf register --accept-tos && ./wgcf generate")),
    h("label", {}, "wgcf-profile.conf"), fileField(ta), ta,
    btn("📥 Импортировать", (b) => {
      const text = ta.value.trim();
      if (!text.includes("[Interface]") || !text.includes("[Peer]")) return fail(new Error("Это не похоже на wgcf-profile.conf"));
      return busy(b, async () => {
        const r = await callR(["warp", "import"], { stdin: text + "\n" });
        haptic(); toast("✅ " + outcome(r.log, "Профиль импортирован"), 3500); back();
      });
    }, "btn-primary btn-block"));
});

route(/^\/tunnels\/warp\/endpoint$/, async (ctx) => {
  const cc = h("input", { placeholder: "DE", maxlength: 2, autocapitalize: "characters", autocomplete: "off" });
  const find = (code) => runJob(ctx, `Поиск endpoint WARP${code ? ` (${code})` : ""}`, ["warp", "endpoint", ...(code ? [code] : [])],
    null, { onBack: back });
  ctx.put(title("🔎 Endpoint WARP"), hint("Перебирает адреса Cloudflare и ставит тот, что отвечает быстрее всех."),
    btn("🌍 Любая страна", () => find(""), "btn-primary btn-block"),
    h("label", {}, "Или страна выхода — две буквы (DE, NL, FI…)"), cc,
    btn("🔎 Искать в этой стране", () => {
      const v = cc.value.trim().toUpperCase();
      if (!/^[A-Z]{2}$/.test(v)) return fail(new Error("Две латинские буквы, например DE"));
      return find(v);
    }, "btn-block"));
});

// Xray
const BALANCERS = [["random", "случайный выход"], ["roundRobin", "по очереди"], ["leastPing", "наименьший пинг"],
  ["leastLoad", "наименьшая нагрузка"], ["off", "выключить"]];

route(/^\/tunnels\/xray$/, async (ctx) => {
  const r = await callR(["xray", "status"]);
  const d = r.data || {}, inst = d.installed, tags = d.tags || [];
  async function outbound(t) {
    const v = await sheet("Выход " + t, [
      ...(d.main !== t ? [{ label: "⭐ Сделать выходом по умолчанию", value: "main" }] : []),
      { label: "🗑 Удалить выход", value: "del" }]);
    if (v === "main") await quick(null, "Выход по умолчанию: " + t, ["xray", "main", t]);
    if (v === "del") await quickAsk(null, `Удалить выход ${t}?`, "Выход удалён", ["xray", "del", t]);
  }
  async function balancer(b) {
    const v = await sheet("⚖️ Как делить трафик между выходами", BALANCERS.map(([k, l]) =>
      ({ label: `${d.balancer === k ? "🔘" : "⚪️"} ${k} — ${l}`, value: k })));
    if (v) await quick(b, "Балансировщик: " + v, ["xray", "balancer", v]);
  }
  ctx.put(title("🛰 Xray"), logCard(r.log),
    inst ? switchRow("🇷🇺 РФ напрямую", "российские сайты мимо Xray", d.ru,
      (on) => runJob(ctx, `РФ-сайты напрямую: ${on ? "вкл" : "выкл"}`, ["xray", "ru", on ? "on" : "off"])) : null,
    inst ? [h("h2", {}, "Выходы"),
      h("div", { class: "card list" }, tags.length ? tags.map((t) => {
        const own = (d.clients || []).filter((c) => c.out === t).map((c) => c.name);
        return h("div", { class: "item", "data-name": "xo-" + t, onclick: () => outbound(t) },
          h("div", { class: "main" }, h("div", { class: "title" }, t, d.main === t ? " " : null, d.main === t ? pill("по умолчанию", "ok") : null),
            own.length ? h("div", { class: "sub" }, "свой выход: " + own.join(", ")) : null),
          h("div", { class: "side" }, icon("chevron-right")));
      }) : h("div", { class: "empty" }, "Выходов нет — добавь ссылкой")),
      tags.length > 1 ? hint(d.per_client ? "Клиенту можно закрепить свой выход: Клиенты → клиент → Маршрут. "
        + "Остальные идут через выход по умолчанию или балансировщик."
        : "Свой выход клиенту — только с inbound tun в самом Xray: обнови Xray.") : null,
      btn("➕ Добавить выход", () => go("/tunnels/xray/add"), "btn-block" + (tags.length ? "" : " btn-primary")),
      tags.length > 1 ? btn(`⚖️ Балансировщик: ${d.balancer || "off"}`, balancer, "btn-block") : null,
      h("h2", {}, "Управление")] : null,
    inst ? null : [hint("Клиенты выходят в интернет через твой сервер VLESS, VMess, Trojan, Shadowsocks или Hysteria2 — "
      + "выходы добавляются ссылками. Можно несколько, с балансировкой."),
    btn("📦 Установить Xray", () => runJob(ctx, "Установка Xray", ["xray", "install"]), "btn-primary btn-block")],
    inst ? h("div", { class: "actions" },
      btn("📦 Обновить", () => runJob(ctx, "Обновление Xray", ["xray", "install"])),
      tags.length && !d.up ? btn("▶️ Включить", () => runJob(ctx, "Включение Xray", ["xray", "up"]), "btn-primary") : null,
      d.up ? btn("⏹ Выключить", (b) => quickAsk(b, tunnelDown("Xray"), "Xray выключен", ["xray", "down"])) : null,
      d.up ? btn("🔄 Перезапустить", () => jobAsk(ctx, "Перезапустить Xray? Клиенты, идущие через него, на несколько секунд "
        + "потеряют связь.", "Перезапуск Xray", ["xray", "restart"])) : null,
      btn("👥 Клиенты", () => go("/tunnels/xray/clients")),
      btn("🩺 Диагностика", () => runJob(ctx, "Диагностика Xray", ["xray", "diag"])),
      btn("🛠 Починить", (b) => busy(b, async () => {
        const res = await callR(["xray", "fix"], { timeout: 300 });
        haptic(); logSheet("🛠 Исправление конфига Xray", res.log);
      })),
      btn("📜 Журнал", () => go("/log/xray")),
      btn("🗑 Удалить", (b) => quickAsk(b, "Удалить Xray: бинарь, конфиг с выходами, службы?", "Xray удалён", ["xray", "remove"]), "btn-danger")) : null);
});

route(/^\/tunnels\/xray\/add$/, async (ctx) => {
  const link = h("textarea", { placeholder: "vless://…", style: "min-height:110px", autocapitalize: "off" });
  ctx.put(title("➕ Выход Xray"), h("label", {}, "Ссылка на сервер: vless://, vmess://, trojan://, ss:// или hysteria2://"), link,
    btn("Добавить", (b) => {
      const v = link.value.trim();
      if (!/^(vless|vmess|trojan|ss|hysteria2|hy2):\/\//.test(v)) return fail(new Error("Это не ссылка Xray"));
      return quick(b, "Выход добавлен", ["xray", "add", v], () => back());
    }, "btn-primary btn-block"));
});

// tun2socks
route(/^\/tunnels\/tun2socks$/, async (ctx) => {
  const d = (await call("t2s", "status")) || {};
  const proxy = h("input", { value: d.proxy || "", placeholder: "5.6.7.8:1080", autocapitalize: "off", autocomplete: "off" });
  ctx.put(title("🧦 tun2socks"),
    h("div", { class: "card" }, h("div", { class: "muted small" }, "Все клиенты выходят через внешний SOCKS5-прокси."),
      kv("Статус", d.up ? h("span", { class: "ok" }, "● включён") : h("span", { class: "muted" }, "○ выключен")),
      d.proxy ? kv("Прокси", d.proxy) : null),
    d.up ? null : [h("label", {}, "Адрес SOCKS5-прокси: IP:ПОРТ"), proxy,
      btn("▶️ Включить", () => {
        const v = proxy.value.trim();
        if (!/^[A-Za-z0-9._-]+:\d{1,5}$/.test(v)) return fail(new Error("Нужен адрес вида IP:ПОРТ"));
        return runJob(ctx, "Включение tun2socks", ["t2s", "up", v]);
      }, "btn-primary btn-block")],
    h("div", { class: "actions", style: "margin-top:8px" },
      d.up ? btn("⏹ Выключить", (b) => quickAsk(b, tunnelDown("tun2socks"), "tun2socks выключен", ["t2s", "down"])) : null,
      btn("📜 Журнал", () => go("/log/tun2socks")),
      d.proxy ? btn("🗑 Удалить", (b) => quickAsk(b, "Удалить tun2socks (служба, бинарь, адрес прокси)?", "tun2socks удалён",
        ["t2s", "remove"]), "btn-danger") : null));
});

// AWG exit-ноды: туннель вкл/выкл, кого вести (все или выбранные), выбор клиентов
// и ноды каждому — на одном экране
route(/^\/tunnels\/exits$/, async (ctx) => {
  const [r, cl] = await Promise.all([callR(["exits", "status"]), loadClients().catch(() => ({ rows: [] }))]);
  const d = r.data || {}, nodes = d.nodes || [], up = !!d.up, mode = d.mode === "peers" ? "peers" : "all";
  // Выход каждого клиента в режиме «выбранные»: off — напрямую, shared — общий выход, иначе нода
  const rows = (cl.rows || []).map((c) => ({ name: c.name, ip: c.ip, online: c.online, exit: c.exit == null ? "shared" : c.exit }));
  const label = (v) => (v === "shared" ? "общий выход" : "нода " + v);
  const onCount = () => rows.filter((c) => c.exit !== "off").length;
  async function balance(b) {
    const cur = d.balancer === "ecmp" ? "ecmp" : d.single || "";
    const v = await sheet("⚖️ Балансировка: одна нода — весь общий трафик через неё; ECMP — поровну между поднятыми",
      [...nodes.map((n) => ({ label: `${cur === n.name ? "🔘" : "⚪️"} Нода ${n.name}`, value: "single|" + n.name })),
        { label: `${cur === "ecmp" ? "🔘" : "⚪️"} ECMP`, value: "ecmp|" }]);
    if (!v) return;
    const [m, node] = v.split("|");
    await quick(b, "Балансировка", ["exits", "balance", m, ...(node ? [node] : [])]);
  }
  // Сам туннель: включить (в выбранном режиме) или выключить — все клиенты напрямую
  const tunSub = h("div", { class: "sub wrap" });
  const subText = () => (!nodes.length ? "сначала добавь ноду ниже" : !up ? "выключен — все клиенты идут напрямую"
    : mode === "all" ? "включён · все клиенты" : `включён · через ноды ${onCount()} из ${rows.length}`);
  const tunnel = h("div", { class: "card item" + (nodes.length ? "" : " dis"), "data-tunnel": up ? "on" : "off",
    onclick: nodes.length ? () => busy(null, async () => {
      const res = await callR(up ? ["exits", "down"] : ["exits", "up", mode]);
      haptic(); toast("✅ " + outcome(res.log, up ? "Exit-ноды выключены" : "Exit-ноды включены"), 3500); render();
    }) : null },
  h("div", { class: "main" }, h("div", { class: "title" }, "Туннель через exit-ноды WG"), tunSub),
  h("div", { class: "switch" + (up ? " on" : "") }));
  // Выбранные клиенты: переключатель у каждого, нода (если их несколько), поиск, все / никого
  let q = "";
  const count = h("span", { class: "muted small" }), list = h("div", { class: "card list exl" });
  const search = h("input", { type: "search", placeholder: "Поиск клиента", autocomplete: "off",
    oninput: () => { q = search.value.trim().toLowerCase(); draw(); } });
  const setExit = (c, v) => busy(null, async () => {
    await call("exits", "client", c.name, v);
    c.exit = v; haptic(); draw();
  });
  async function pickNode(c) {
    const v = await sheet(`🚪 Выход: ${c.name}`, [["shared", "Общий выход"], ...nodes.map((n) => [n.name, "Нода " + n.name])]
      .map(([val, l]) => ({ label: `${c.exit === val ? "🔘" : "⚪️"} ${l}`, value: val })));
    if (v && v !== c.exit) { await setExit(c, v); toast(`${c.name} → ${label(v)}`); }
  }
  const bulk = (all) => (b) => busy(b, async () => {
    await call("exits", "client", all ? "all" : "none");
    rows.forEach((c) => { if (!all) c.exit = "off"; else if (c.exit === "off") c.exit = "shared"; });
    haptic(); toast(all ? "Все клиенты — через exit-ноды" : "Никого через exit-ноды — все напрямую", 3000); draw();
  });
  function draw() {
    tunSub.textContent = subText();
    count.textContent = `через ноды: ${onCount()} из ${rows.length}`;
    const vis = rows.filter((c) => !q || c.name.toLowerCase().includes(q) || (c.ip || "").includes(q));
    list.replaceChildren(...(vis.length ? vis.map((c) => {
      const on = c.exit !== "off", flip = () => setExit(c, on ? "off" : "shared");
      return h("div", { class: "item", "data-name": c.name },
        h("div", { class: "dot" + (c.online ? " on" : "") }),
        h("div", { class: "main", onclick: flip }, h("div", { class: "title" }, c.name),
          h("div", { class: "sub" }, `${c.ip} · ${on ? label(c.exit) : "напрямую"}`)),
        on && nodes.length > 1 ? h("button", { class: "chip", title: "Выбрать ноду", onclick: () => pickNode(c) }, label(c.exit), " ▾") : null,
        h("div", { class: "switch" + (on ? " on" : ""), role: "switch", "aria-checked": String(on), "aria-label": c.name, onclick: flip }));
    }) : [h("div", { class: "empty" }, q ? "Никого не нашлось" : "Клиентов нет")]));
  }
  draw();
  const seg = h("div", { class: "seg exmode" }, [["all", "Все клиенты"], ["peers", "Выбранные"]].map(([k, t]) =>
    h("button", { class: mode === k ? "on" : null, onclick: (ev) => (mode === k ? null
      : quick(ev.currentTarget, k === "all" ? "Через ноды — все клиенты" : "Через ноды — выбранные", ["exits", "mode", k])) }, t)));
  ctx.put(title("🚪 Exit-ноды WG"), hint("Клиенты выходят в интернет через другие AWG/WG-серверы."),
    tunnel,
    nodes.length ? [h("h2", {}, "Кого вести через ноды"), seg,
      mode === "peers" ? [
        h("div", { class: "ctools", style: "margin-top:12px" }, h("div", { class: "search" }, icon("search"), search),
          btn("✅ Все", bulk(true)), btn("➖ Никого", bulk(false))),
        h("div", { class: "row", style: "margin:0 4px 8px" }, count), list,
        hint(up ? "Включено — клиент идёт через ноды, выключено — напрямую через сервер."
          : "Туннель выключен — выбор сохранится и сработает, когда его включишь.")]
        : hint("Все клиенты идут через ноды. «Выбранные» — отметить, кого вести; остальные — напрямую.")] : null,
    h("h2", {}, "Ноды"),
    h("div", { class: "card list" }, nodes.length ? nodes.map((n) => h("div", { class: "item", onclick: () =>
      quickAsk(null, `Удалить ноду ${n.name}? Её клиенты перейдут на общий выход.`, `Нода ${n.name} удалена`, ["exits", "del", n.name]) },
    h("div", { class: "dot" + (n.up ? " on" : " bad") }),
    h("div", { class: "main" }, h("div", { class: "title" }, n.name), h("div", { class: "sub" }, n.up ? "поднята" : "лежит")),
    h("div", { class: "side bad" }, icon("trash-2")))) : h("div", { class: "empty" }, "Нод нет")),
    btn("➕ Добавить ноду", () => go("/tunnels/exits/add"), "btn-block" + (nodes.length ? "" : " btn-primary")),
    h("div", { class: "actions", style: "margin-top:8px" },
      nodes.length ? btn("⚖️ Балансировка", balance) : null,
      btn("📜 Журнал", () => go("/log/exits"))),
    logCard(r.log));
});

route(/^\/tunnels\/exits\/add$/, async (ctx) => {
  const name = h("input", { placeholder: "de1", maxlength: 6, autocapitalize: "off", autocomplete: "off" });
  const ta = h("textarea", { placeholder: "[Interface]\n…\n\n[Peer]\nEndpoint = …", style: "min-height:160px" });
  ctx.put(title("➕ Exit-нода WG"),
    h("label", {}, "Имя: латиница, цифры, _, до 6 символов"), name,
    h("label", {}, "Клиентский конфиг AWG/WG этой ноды"), fileField(ta), ta,
    hint("Маршрут всего сервера конфиг не заберёт: awg2 ставит Table = off."),
    btn("Добавить", (b) => {
      const n = name.value.trim(), text = ta.value.trim();
      if (!/^[A-Za-z0-9_]{1,6}$/.test(n)) return fail(new Error("Имя: латиница, цифры, _, до 6 символов"));
      if (!text.includes("[Interface]") || !text.includes("Endpoint")) return fail(new Error("Нужен клиентский конфиг с [Interface] и Endpoint"));
      return runJob(ctx, "Exit-нода " + n, ["exits", "add", n], null, { stdin: text + "\n", onBack: back });
    }, "btn-primary btn-block"));
});

// Выбор клиентов и нод теперь на экране exit-нод
route(/^\/tunnels\/exits\/clients$/, async () => replace("/tunnels/exits"));

// Каскад портов
route(/^\/tunnels\/cascade$/, async (ctx) => {
  const rows = (await call("cascade", "list")) || [];
  ctx.put(title("🔀 Каскад портов"), hint("Трафик на порт этого сервера уходит на другой сервер."),
    h("div", { class: "card list" }, rows.length ? rows.map((x) => h("div", { class: "item", onclick: () =>
      quickAsk(null, `Удалить правило ${x.proto.toUpperCase()} ${x.in} → ${x.dst}:${x.out}?`, "Правило удалено", ["cascade", "del", x.proto, String(x.in)]) },
    h("div", { class: "dot" + (x.applied ? " on" : " bad") }),
    h("div", { class: "main" }, h("div", { class: "title" }, `${x.proto.toUpperCase()} ${x.in} → ${x.dst}:${x.out}`),
      h("div", { class: "sub" }, [x.applied ? "применено" : "записано, но в iptables нет", x.comment].filter(Boolean).join(" · "))),
    h("div", { class: "side bad" }, icon("trash-2")))) : h("div", { class: "empty" }, "Правил нет")),
    btn("➕ Добавить правило", () => go("/tunnels/cascade/add"), "btn-primary btn-block"),
    h("div", { class: "actions", style: "margin-top:8px" },
      rows.length ? btn("🔁 Переприменить", (b) => quick(b, "Правила переприменены", ["cascade", "reapply"])) : null,
      btn("🩺 Диагностика", (b) => busy(b, async () => logSheet("🩺 Каскад", (await callR(["cascade", "diag"])).log))),
      btn("📜 Журнал", () => go("/log/cascade")),
      rows.length ? btn("🧹 Удалить все", (b) => quickAsk(b, "Удалить все правила каскада?", "Правила удалены", ["cascade", "clear"])) : null,
      btn("🗑 Удалить каскад", (b) => quickAsk(b, "Удалить каскад полностью: правила и службу?", "Каскад удалён", ["cascade", "remove"]), "btn-danger")));
});

route(/^\/tunnels\/cascade\/add$/, async (ctx) => {
  let proto = "udp";
  const protoBox = h("div", { class: "chips" });
  const drawP = () => protoBox.replaceChildren(...[["udp", "UDP"], ["tcp", "TCP"], ["both", "UDP и TCP"]].map(([v, l]) =>
    h("button", { class: "chip" + (proto === v ? " on" : ""), onclick: () => { proto = v; drawP(); } }, l)));
  drawP();
  const pin = h("input", { type: "number", min: 1, max: 65535, placeholder: "51820" });
  const dst = h("input", { placeholder: "5.6.7.8", inputmode: "decimal", autocomplete: "off" });
  const pout = h("input", { type: "number", min: 1, max: 65535, placeholder: "тот же" });
  const cm = h("input", { maxlength: 60, placeholder: "например, имя сервера" });
  ctx.put(title("➕ Правило каскада"),
    h("label", {}, "Протокол — UDP для AWG и WireGuard"), protoBox,
    h("label", {}, "Порт на этом сервере"), pin,
    h("label", {}, "Публичный IPv4 сервера назначения"), dst,
    h("label", {}, "Порт на сервере назначения"), pout,
    h("label", {}, "Комментарий (необязательно)"), cm,
    btn("Добавить", (b) => {
      const a = pin.value.trim(), ip = dst.value.trim(), o = pout.value.trim() || a, c = cm.value.trim();
      if (!validPort(a)) return fail(new Error("Порт на этом сервере — число 1-65535"));
      if (!validIp(ip)) return fail(new Error("Нужен IPv4, например 5.6.7.8"));
      if (!validPort(o)) return fail(new Error("Порт назначения — число 1-65535"));
      return quick(b, "Правило добавлено", ["cascade", "add", proto, a, ip, o, ...(c ? [c] : [])], () => back());
    }, "btn-primary btn-block"));
});

// Шифрованный DNS
route(/^\/tunnels\/dns$/, async (ctx) => {
  const r = await callR(["dns", "status"]);
  const d = r.data || {}, inst = d.installed;
  const norm = (s) => (s || "").split(/[\s,]+/).filter(Boolean).join(" ");
  const cur = norm(d.upstream);
  async function off(b) {
    const v = await sheet("Выключить шифрованный DNS? Клиенты вернутся к DNS из своих конфигов.",
      [{ label: "⏹ Выключить", value: "off" }, { label: "🗑 Удалить совсем, с dnscrypt-proxy", value: "purge", cls: "bad" }]);
    if (v) await quick(b, "DNS выключен", ["dns", "remove", ...(v === "purge" ? ["purge"] : [])]);
  }
  ctx.put(title("🔐 Шифрованный DNS"), hint("Запросы клиентов идут через dnscrypt-proxy по DoH, DoT (853) закрыт."),
    logCard(r.log),
    inst ? [h("h2", {}, "Резолверы"),
      h("div", { class: "card list" }, (d.presets || []).map((p) => h("div", { class: "item", onclick: () =>
        (norm(p.names) === cur ? null : quick(null, "Резолверы изменены", ["dns", "upstream", p.names])) },
      h("div", { class: "radio" + (norm(p.names) === cur ? " on" : "") }),
      h("div", { class: "main" }, h("div", { class: "title" }, p.label), h("div", { class: "sub" }, p.names)))),
      h("div", { class: "item", onclick: () => go("/tunnels/dns/manual") }, h("div", { class: "radio" }),
        h("div", { class: "main" }, h("div", { class: "title" }, "✏️ Вручную…"), h("div", { class: "sub" }, "имена из public-resolvers"))))] : null,
    h("div", { class: "actions", style: "margin-top:8px" },
      !inst ? btn("▶️ Включить", () => runJob(ctx, "Шифрованный DNS", ["dns", "install"]), "btn-primary") : null,
      !inst ? btn("⚠️ Принудительно", () => jobAsk(ctx, "Если на сервере работает свой DNS (Pi-hole, Unbound, bind), "
        + "перехват уведёт клиентов мимо него. Включить всё равно?", "Шифрованный DNS", ["dns", "install", "force"])) : null,
      inst ? btn("🔄 Перезапустить", (b) => quick(b, "DNS перезапущен", ["dns", "restart"])) : null,
      btn("📜 Журнал", () => go("/log/dns")),
      inst ? btn("⏹ Выключить", off, "btn-danger") : null),
    inst ? null : hint("«Принудительно» — если на сервере уже работает свой DNS (Pi-hole, Unbound, bind)"));
});

route(/^\/tunnels\/dns\/manual$/, async (ctx) => {
  const d = (await call("dns", "status")) || {};
  const names = h("input", { value: d.upstream || "", placeholder: "cloudflare, google", autocapitalize: "off", autocomplete: "off" });
  ctx.put(title("✏️ Резолверы"),
    h("label", {}, "Имена через запятую — из списка public-resolvers (github.com/DNSCrypt/dnscrypt-resolvers)"), names,
    btn("Сохранить", (b) => {
      const v = names.value.trim();
      if (!/^[A-Za-z0-9_, -]+$/.test(v)) return fail(new Error("Допустимы латиница, цифры, дефис и запятая"));
      return quick(b, "Резолверы изменены", ["dns", "upstream", v], () => back());
    }, "btn-primary btn-block"));
});

// Внешняя ссылка — браузером Telegram, не внутри панели
const extLink = (url, text) => h("a", { href: url, onclick: (ev) => {
  ev.preventDefault();
  if (tg && tg.openLink) tg.openLink(url); else window.open(url, "_blank", "noopener");
} }, text || url);

// ── Диагностика ───────────────────────────────────────────
route(/^\/diag$/, async (ctx) => {
  const r = await callR(["diag", "status"]);
  ctx.put(title("🩺 Диагностика"), logCard(r.log),
    btn("🔄 Обновить сводку", () => render(), "btn-block"),
    h("h2", {}, "Проверки"),
    h("div", { class: "card list" },
      menuItem("🌍 Домены мимикрии: мир", "какие домены пула отвечают отсюда", () => runJob(ctx, "Домены мимикрии (мир)", ["diag", "domains", "world"])),
      menuItem("📍 Домены мимикрии: Россия", "пул для серверов в РФ", () => runJob(ctx, "Домены мимикрии (Россия)", ["diag", "domains", "ru"])),
      menuItem("🎯 Тест мимикрии", "захват первых пакетов клиента", () => go("/diag/sniff")),
      menuItem("🔍 DPI у клиента", "проверка со стороны клиента", () => go("/diag/dpi"))),
    h("h2", {}, "Ещё"),
    h("div", { class: "card list" },
      menuItem("📜 Журналы служб", "последние строки журнала", () => go("/diag/logs")),
      menuItem("🧩 Модуль ядра", "версии, пересборка, откат", () => go("/server/module"))));
});

route(/^\/diag\/logs$/, async (ctx) => {
  ctx.put(title("📜 Журналы"),
    h("div", { class: "card list" }, Object.entries(LOGS).map(([name, label]) => menuItem(label, name, () => go("/log/" + name)))));
});

route(/^\/diag\/sniff$/, async (ctx) => {
  const rows = (await call("diag", "sniff-list")) || [];
  async function listen(name) {
    if (!await confirmTg(`На устройстве ${name} отключись от VPN. Нажми OK — и в течение 20 секунд подключись снова.`)) return;
    await runJob(ctx, `Тест мимикрии: ${name}`, ["diag", "sniff", name], null, { onBack: back });
  }
  ctx.put(title("🎯 Тест мимикрии"),
    hint("Сервер 20 секунд слушает первые пакеты клиента и проверяет, видны ли пакеты мимикрии и на что они похожи."),
    rows.length ? [h("h2", {}, "Клиент"),
      h("div", { class: "card list" }, rows.slice(0, 60).map((c) =>
        menuItem(c.name, (c.endpoint || "").replace(/:\d+$/, ""), () => listen(c.name))))]
      : [h("div", { class: "card empty" }, "Нет клиентов, которые уже подключались. Подключись с устройства и обнови."),
        btn("🔄 Обновить", () => render(), "btn-block")]);
});

const DPI_CMD = {
  docker: "docker run --rm -it --pull=always ghcr.io/runnin4ik/dpi-detector:latest",
  python: "git clone https://github.com/Runnin4ik/dpi-detector.git\ncd dpi-detector && python -m pip install -r requirements.txt && python dpi_detector.py",
};
route(/^\/diag\/dpi$/, async (ctx) => {
  const code = (text) => h("pre", { style: "cursor:pointer", onclick: () => copy(text) }, text);
  ctx.put(title("🔍 DPI у клиента"),
    hint("Запускать на устройстве клиента, не на сервере. Нажми на команду — она скопируется."),
    h("label", {}, "Docker"), code(DPI_CMD.docker),
    h("label", {}, "Python"), code(DPI_CMD.python),
    hint(["Windows и macOS — готовые сборки в ", extLink("https://github.com/Runnin4ik/dpi-detector/releases", "Releases"), "."]),
    h("h2", {}, "Что делать с результатом"),
    h("div", { class: "card small" },
      h("div", {}, "• рабочий у провайдера клиента домен → домен мимикрии (карточка клиента → Мимикрия)"),
      h("div", {}, "• подмена DNS / перехват UDP 53 → Туннели → Шифрованный DNS"),
      h("div", {}, "• обрыв после первых КБ → профиль «AmneziaVPN» и короче I1-I5")),
    hint("Сторонний проект (MIT), awg2 его не ставит."));
});

// ── Бэкапы ────────────────────────────────────────────────
const BACKUP_MAX = 20 * 1024 * 1024;
// «20260930_035321» из метаданных бэкапа → «30.09.2026 03:53»
const fmtStamp = (s) => { const m = /^(\d{4})(\d\d)(\d\d)_(\d\d)(\d\d)/.exec(s || ""); return m ? `${m[3]}.${m[2]}.${m[1]} ${m[4]}:${m[5]}` : s; };
// Отправка бэкапа в чат с отметкой на экране
function sendBackup(path, note) {
  note.textContent = WEB ? "⬇️ Скачиваю…" : "📥 Отправляю в чат…";
  return (WEB ? download({ what: "backup", path }) : post("/api/send", { what: "backup", path })).then(() => {
    note.textContent = (WEB ? "✅ Файл скачан." : "✅ Файл — в чате с ботом.") + " В нём приватные ключи — храни как пароль.";
    haptic();
  }, (e) => { note.textContent = "❌ " + e.message; });
}
async function uploadBackup(file) {
  if (file.size > BACKUP_MAX) throw new Error("Файл больше 20 МБ — это не бэкап awg2");
  const r = await fetch(url("/api/backup/upload"), { method: "POST", body: file, credentials: "same-origin",
    headers: WEB ? { "Content-Type": "application/octet-stream" }
      : { Authorization: "tma " + (tg ? tg.initData : ""), "Content-Type": "application/octet-stream" } })
    .catch(() => { throw new Error("Нет связи с сервером"); });
  const d = await r.json().catch(() => ({}));
  if (!r.ok || d.ok === false) throw new Error(d.error || `HTTP ${r.status}`);
  return d.path;
}

// Автобэкап: «ежедневно · хранить 7 · последний 02.10 04:00»
const BACKUP_MODES = [["off", "Выкл"], ["day", "Каждый день"], ["week", "Раз в неделю"]];
function autoLine(b) {
  if (b.mode === "off") return "выключен";
  const mode = { day: "ежедневно", week: "еженедельно" }[b.mode];
  return `${mode} · хранить ${b.keep} · последний ${b.last ? fmtTime(b.last) : "ещё не было"}` + (b.error ? ` · ⚠️ ${b.error}` : "");
}
function autoBackupCard(a, redraw) {
  const b = a.backup;
  const set = (body, msg) => busy(null, async () => {
    const r = await post("/api/alerts", body);
    haptic(); if (msg) toast(msg, 3000);
    redraw(r);
  });
  // Веб-панель без Telegram-бота: присылать некому — настройки не показываем
  return h("div", { class: "card", "data-name": "autobackup", style: "margin-top:12px" },
    h("div", { class: "kv" }, h("b", {}, "Автобэкап"), h("span", { class: "muted small" }, autoLine(b))),
    a.owner && !noBot() ? [
      segText(BACKUP_MODES, b.mode, (m) => set({ backup_mode: m }, m === "off" ? "Автобэкап выключен" : "Первый автобэкап придёт в чат в течение пары минут")),
      h("div", { class: "row", style: "gap:8px;align-items:center;margin-top:8px" }, h("span", { class: "muted small" }, "Хранить на сервере:"),
        segText([3, 7, 14, 30].map((n) => [n, String(n)]), b.keep, (n) => set({ backup_keep: n }))),
      b.mode !== "off" && !WEB ? h("button", { class: "btn-block", style: "margin-top:8px", onclick: (ev) => busy(ev.currentTarget, async () => {
        toast("Делаю автобэкап…", 4000);
        const r = await post("/api/alerts", { backup_now: true });
        redraw(r); haptic();
        toast({ done: "💾 Автобэкап — в чате", busy: "⏳ Идёт другая операция — повтори, когда она закончится",
          fail: "❌ Автобэкап не удался — причина в чате, повтор через час" }[r.backup_now] || "Автобэкап не сделан", 4000);
      }) }, "💾 Сделать сейчас") : null,
    ] : null,
    hint((WEB ? "Автобэкап присылает Telegram-бот" + (S.me && S.me.tg_bot ? "" : " — он не установлен") + ". " : "")
      + "Полный бэкап по расписанию — файлом в чат, только владельцам: в нём приватные ключи. "
      + `Из автобэкапов на сервере остаются последние ${b.keep || 7}, сделанные вручную не трогаются.`));
}

route(/^\/backup$/, async (ctx) => {
  const [rowsAll, alertsInfo] = await Promise.all([call("backup", "list"), post("/api/alerts").catch(() => null)]);
  const rows = (rowsAll || []).slice(0, 30);
  const autoBox = h("div");
  const drawAuto = (a) => a && autoBox.replaceChildren(autoBackupCard(a, drawAuto));
  drawAuto(alertsInfo);
  // Без accept: на части Android фильтр по типу прячет .tar.gz; что это бэкап, проверит awg2
  const file = h("input", { type: "file", style: "display:none",
    onchange: () => busy(null, async () => {
      const f = file.files[0];
      if (!f) return;
      toast("Загружаю " + f.name + "…", 4000);
      S.restore = { path: await uploadBackup(f), name: f.name };
      go("/backup/restore");
    }) });
  async function pick(b) {
    const v = await sheet(`${b.full ? "📁" : "🗜"} ${b.name}`, [{ label: TO("📥 Прислать в чат", "⬇️ Скачать"), value: "send" },
      { label: "♻️ Восстановить из него", value: "restore" }]);
    if (v === "send") {
      await busy(null, async () => {
        if (!WEB) toast("📥 Отправляю в чат…", 4000);
        await deliver({ what: "backup", path: b.path }, "✅ Бэкап — в чате с ботом");
      });
    } else if (v === "restore") {
      S.restore = { path: b.path, name: b.name };
      go("/backup/restore");
    }
  }
  ctx.put(title("💾 Бэкапы"),
    hint("Полный бэкап: сервер и клиенты, аккаунт WARP, WG + обфускатор, настройки туннелей. Хранятся в ~/awg_backup на сервере."),
    h("div", { class: "actions" },
      btn("💾 Создать", () => runJob(ctx, "Бэкап", ["backup", "create"], (d) => {
        const note = h("div", { class: "small", style: "margin-top:6px" });
        if (d && d.path) sendBackup(d.path, note);
        return h("div", { class: "card" }, kv("Файл", (d && d.path || "").split("/").pop()), kv("Размер", fmtBytes(d && d.size)), note);
      }), "btn-primary"),
      btn("📤 Из файла", () => file.click())), file, autoBox,
    h("h2", {}, "На сервере"),
    h("div", { class: "card list" }, rows.length ? rows.map((b) => h("div", { class: "item", onclick: () => pick(b) },
      h("div", { class: "ibox" }, icon(b.full ? "folder" : "file-archive")),
      h("div", { class: "main" }, h("div", { class: "title" }, fmtTime(b.time)),
        h("div", { class: "sub" }, `${b.full ? "полный, каталог" : "архив"} · ${fmtBytes(b.size)}`)),
      h("div", { class: "side" }, icon("chevron-right")))) : h("div", { class: "empty" }, "Бэкапов на сервере нет")),
    hint("Полный бэкап лежит каталогом, рядом — его архив. Восстановить можно и из архива прежнего бота."));
});

route(/^\/backup\/restore$/, async (ctx) => {
  const rs = S.restore;
  if (!rs) return replace("/backup");
  const d = (await call("backup", "inspect", rs.path)) || {};
  const meta = Object.fromEntries((d.meta || "").split("\n").filter((l) => l.includes("="))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
  const opt = { wgobf: !!d.wgobf, tunnels: !!d.tunnels };
  ctx.put(title("♻️ Восстановление"),
    h("div", { class: "card" },
      kv("Файл", rs.name),
      meta.timestamp ? kv("Создан", fmtStamp(meta.timestamp)) : null,
      meta.hostname ? kv("Сервер", meta.hostname) : null,
      meta.toolza ? kv("Версия", meta.toolza) : null,
      meta.awg_version ? kv("Протокол", "AWG " + meta.awg_version) : null,
      kv("Клиентов", d.clients || 0),
      kv("WARP", d.warp ? "аккаунт есть" : "нет")),
    h("div", { class: "card warn small" },
      h("div", {}, "Сервер и клиенты восстанавливаются всегда — текущий сервер будет заменён; его awg0.conf сохраняется рядом."),
      h("div", { style: "margin-top:4px" }, "Туннели восстанавливаются выключенными — их включают вручную.")),
    d.wgobf ? switchRow("🛡 Обфускатор", "WG + обфускатор из бэкапа", true, (on) => { opt.wgobf = on; }) : null,
    d.tunnels ? switchRow("🌐 Туннели", "настройки Xray, exit-нод, каскада и DNS", true, (on) => { opt.tunnels = on; }) : null,
    btn("♻️ Восстановить", async () => {
      if (!await confirmTg("Заменить текущий сервер и клиентов данными из бэкапа?")) return;
      S.restore = null;
      await runJob(ctx, "Восстановление из бэкапа", ["backup", "restore", rs.path, ...["wgobf", "tunnels"].filter((k) => opt[k])],
        null, { onBack: () => replace("/backup") });
    }, "btn-danger btn-block"),
    btn("✖️ Отмена", () => { S.restore = null; back(); }, "btn-block"));
});

// ── Обновление ────────────────────────────────────────────
function updateBot(ctx) {
  return jobAsk(ctx, "Обновить бота из канала обновлений? Он перезапустится, панель подождёт и покажет итог.",
    "Обновление бота", ["bot", "update"], () => [
      hint("Панель уже старая — открой её заново, чтобы загрузилась новая версия."),
      btn("🔄 Открыть панель заново", () => location.reload(), "btn-primary btn-block")]);
}

// Список изменений из CHANGELOG.md канала: **жирный**, `код`, пункты «- »,
// остальное — абзацы. Только DOM-узлы — текст из GitHub не идёт в innerHTML
function mdInline(text) {
  return text.split(/(\*\*[^*]+\*\*|`[^`]+`)/).filter(Boolean).map((t) =>
    (t.length > 4 && t.startsWith("**") && t.endsWith("**") ? h("b", {}, t.slice(2, -2))
      : t.length > 2 && t.startsWith("`") && t.endsWith("`") ? h("code", {}, t.slice(1, -1)) : t));
}
function mdBlocks(md) {
  const blocks = [];
  for (const raw of (md || "").split("\n")) {
    const line = raw.trim(), last = blocks[blocks.length - 1], li = raw.match(/^[-•]\s+(.*)$/);
    if (!line) blocks.push(["gap"]);
    else if (li) blocks.push(["li", li[1].trim()]);
    else if (last && last[0] === "li" && /^\s/.test(raw)) last[1] += " " + line;
    else if (last && last[0] === "p") last[1] += " " + line;
    else blocks.push(["p", line]);
  }
  const out = [];
  let ul = null;
  for (const [kind, text] of blocks) {
    if (kind === "li") {
      if (!ul) out.push(ul = h("ul"));
      ul.append(h("li", {}, mdInline(text)));
    } else {
      ul = null;
      if (kind === "p") out.push(h("p", {}, mdInline(text)));
    }
  }
  return out;
}
function changelogView(c) {
  const secs = c.sections || [];
  if (!secs.length) return [h("div", { class: "muted small" }, "В списке изменений нет раздела для этой версии")];
  const head = c.newer && secs.length > 1 ? `Что нового: ${c.current} → ${secs[0].version}` : `Что нового в ${secs[0].version}`;
  return [h("div", { class: "chlog-h" }, icon("file-text"), head),
    h("div", { class: "chlog" }, secs.map((x) => [
      h("div", { class: "chlog-v" }, x.version, x.title ? h("span", {}, " · " + x.title) : null), mdBlocks(x.body)]))];
}
// Установлена новая версия awg2 — шапка показывает её сразу, не дожидаясь главной
const setVersion = (v) => {
  if (!v || v === S.version) return;
  S.version = v;
  if (S.update === v) S.update = "";
  drawTop();
};
// Версия в канале новее установленной ("" — нет): стрелка ↑ в шапке
const setUpdate = (v) => { v = v || ""; if (v !== (S.update || "")) { S.update = v; drawTop(); } };

route(/^\/update$/, async (ctx) => {
  const [d, me] = await Promise.all([call("update", "status"), post("/api/me")]);
  const beta = d.channel === "beta";
  setVersion(d.version);
  // Итог проверки меняет на месте только «Доступна» и кнопку обновления —
  // экран не перерисовывается целиком и не моргает
  const avail = h("span"), updBox = h("div");
  const applyLatest = (v) => {
    setUpdate(v);
    avail.replaceChildren(v ? h("b", { class: "ok" }, v) : h("span", { class: "muted" }, "новее нет"));
    updBox.replaceChildren(...(v ? [btn(`⬆️ Обновить до ${v}`, () => runJob(ctx, "Обновление awg2", ["update", "install"], (res) => [
      setVersion((res && res.version) || v),
      h("div", { class: "card" }, kv("Установлена", (res && res.version) || v)),
      hint("Бот обновляется отдельно — из того же канала."),
      btn("🤖 Обновить бота", () => updateBot(ctx), "btn-primary btn-block")]), "btn-ok btn-block")] : []));
  };
  applyLatest(d.available || "");
  const notes = h("div", { class: "card" }, h("div", { class: "muted small" }, "Загружаю список изменений…"));
  const loadNotes = () => call("update", "changelog").then((c) => {
    if (!ctx.live()) return;
    notes.replaceChildren(...changelogView(c || {}));
    // awg2 сверил CHANGELOG с кэшем проверки и, если тот отстал, спросил канал
    // заново: «Доступна» и кнопка — та же версия, что в списке и что поставится
    if (c && typeof c.available === "string") {
      if (c.available !== (S.update || "")) applyLatest(c.available);
    } else if (c && c.newer && !S.update) {
      // awg2 старее: в канале новее, а кэш не знает — проверить сейчас
      call("update", "check").then((r) => { if (ctx.live() && r) applyLatest(r.newer ? r.latest : ""); }).catch(() => {});
    }
  })
    .catch(() => { if (ctx.live()) notes.replaceChildren(h("div", { class: "muted small" }, "Список изменений недоступен — нет связи с GitHub")); });
  loadNotes();
  async function check(b) {
    await busy(b, async () => {
      const r = await call("update", "check");
      applyLatest(r.newer ? r.latest : "");
      haptic();
      toast(r.newer ? `⬆️ Доступна ${r.latest}` : `Обновлений нет — в канале ${r.latest}`, 3000);
      loadNotes();
    });
  }
  async function channel(b) {
    const to = beta ? "stable" : "beta";
    if (to === "beta" && !await confirmTg("Бета — ранние сборки: правки приезжают раньше, но могут быть сырыми. Переключиться?")) return;
    await busy(b, async () => {
      await call("update", "channel", to);
      chanGen++;
      S.channel = to;
      await call("update", "check").catch(() => null);
      drawTop();
      haptic(); toast(to === "beta" ? "Канал: бета" : "Канал: стабильный"); render();
    });
  }
  ctx.put(title("⬆️ Обновление"),
    h("div", { class: "card" },
      kv("awg2", d.version || "?"),
      kv("Канал", beta ? "🧪 бета — ранние сборки" : "стабильный"),
      kv("Доступна", avail),
      kv("Бот", me.bot || "?"),
      h("div", { class: "muted small" }, d.repo || "")),
    updBox,
    h("div", { class: "actions", style: "margin-top:8px" },
      btn("🔎 Проверить", check),
      btn("🤖 Обновить бота", () => updateBot(ctx)),
      btn("♻️ Переустановить", () => jobAsk(ctx, "Поставить версию из канала поверх текущей? Если в канале версия старше — это откат.",
        "Переустановка awg2", ["update", "install", "force"], (res) => [setVersion(res && res.version)])),
      btn(beta ? "🔀 На стабильный" : "🧪 Бета-канал", channel)),
    hint("«Переустановить» — заново из текущего канала, даже без новой версии."),
    notes);
});

// ── WG + обфускатор ───────────────────────────────────────
const WGOBF_DNS = [["Cloudflare", "1.1.1.1, 1.0.0.1"], ["Google", "8.8.8.8, 8.8.4.4"], ["Quad9", "9.9.9.9, 149.112.112.112"]];
const wgobfOnline = (c) => c.ago != null && c.ago < 180;
const wgobfSeen = (c) => (c.ago == null ? pill("не подключался") : wgobfOnline(c) ? pill("онлайн · " + fmtDur(c.ago), "ok")
  : pill(fmtDur(c.ago) + " назад"));
const sendWgobf = (b, name, what) => busy(b, () => deliver({ what, name },
  what === "wgobf" ? "Ссылка, конфиг и файл .conf — в чате с ботом" : "Архив для Linux — в чате с ботом"));

function wgobfInstall(ctx, d) {
  const f = { masking: "STUN", clean: false, dns: 0 };
  const port = h("input", { type: "number", min: 1024, max: 65535, placeholder: "случайный" });
  const name = h("input", { placeholder: "client1", maxlength: 32, autocapitalize: "off", autocomplete: "off" });
  const box = h("div");
  const draw = () => box.replaceChildren(
    h("label", {}, "Маскировка у клиентов"),
    segText([["STUN", "STUN · видеозвонок"], ["NONE", "NONE · только XOR"]], f.masking, (v) => { f.masking = v; draw(); }),
    h("label", {}, "DNS клиентов"),
    segText(WGOBF_DNS.map(([l], i) => [i, l]), f.dns, (v) => { f.dns = v; draw(); }),
    h("label", {}, "UDP-порт обфускатора"), port,
    h("label", {}, "Имя первого клиента"), name,
    h("div", { style: "margin-top:10px" }, switchRow("Чистый WG", "пускать и обычный WireGuard без обфускатора (iOS) — его DPI видит",
      f.clean, (on) => { f.clean = on; })));
  draw();
  ctx.put(title("Обфускатор"),
    ecard({ name: "WG + обфускатор", right: pill("не установлен"), meta: [tag("wg-obfuscator " + (d.version || ""))],
      lines: ["отдельный WireGuard за обфускатором — как Phobos"] }),
    hint("AWG не трогает. Клиентам нужен wg-obfuscator рядом с WireGuard: роутер Keenetic (AWG Manager → «Phobos»), "
      + "Linux, Windows, Android — комплект это описывает."),
    box,
    btn("📦 Установить", () => {
      const p = port.value.trim(), n = name.value.trim() || "client1";
      if (p && !validPort(p, 1024)) return fail(new Error("Порт — число 1024-65535"));
      if (!/^[A-Za-z0-9_-]{1,32}$/.test(n)) return fail(new Error("Имя: латиница, цифры, _ и -, до 32"));
      const args = ["wgobf", "install", `masking=${f.masking}`, `clean=${f.clean ? 1 : 0}`, `client=${n}`,
        `dns=${WGOBF_DNS[f.dns][1]}`, ...(p ? [`port=${p}`] : [])];
      return runJob(ctx, "Установка WG + обфускатор", args, () =>
        btn(`📄 Комплект ${n}`, () => go(`/wgobf/client/${encodeURIComponent(n)}`), "btn-primary btn-block"));
    }, "btn-primary btn-block"));
}

route(/^\/wgobf$/, async (ctx) => {
  const r = await callR(["wgobf", "status"]);
  const d = r.data || {};
  if (!d.installed) return wgobfInstall(ctx, d);
  const rows = (await call("wgobf", "clients")) || [];
  const online = rows.filter(wgobfOnline).length;
  const mask = (v) => quick(null, "Маскировка " + v, ["wgobf", "masking", v]);
  ctx.put(title("Обфускатор"),
    ecard({ state: d.running ? "on" : "bad", name: "WG + обфускатор", attrs: { "data-name": "wgobf" },
      right: pill(d.running ? "работает" : "остановлен", d.running ? "ok" : "bad"),
      meta: [tag(d.masking || "?", "accent", "drama"), tag(d.clean ? "чистый WG можно" : "только обфускатор", d.clean ? "warn" : ""),
        tag("wg-obfuscator " + (d.version || ""))],
      lines: [h("span", { style: "cursor:pointer", onclick: (ev) => { ev.stopPropagation(); copy(d.endpoint); } },
        d.endpoint || "", " ", icon("copy"))],
      acts: [act("refresh-cw", "Рестарт", (b) => quickAsk(b, "Перезапустить обфускатор? Его клиенты на несколько секунд потеряют "
        + "связь и переподключатся сами.", "Перезапущено", ["wgobf", "restart"])),
        act("key", "Ключ", (b) => quickAsk(b, "Сменить ключ обфускатора? Все клиенты отключатся, пока не получат новый комплект.",
          "Ключ сменён", ["wgobf", "rotate-key"])),
        act("file-text", "Журнал", () => go("/log/wgobf"))] }),
    statGrid([
      [`${online}/${rows.length}`, "Клиенты онлайн", "рукопожатие за 3 минуты"],
      [d.masking || "?", "Маскировка", d.masking === "STUN" ? "под видеозвонок" : "только XOR"],
    ]),
    h("label", {}, "Маскировка у клиентов"),
    segText([["STUN", "STUN · видеозвонок"], ["NONE", "NONE · только XOR"]], d.masking, (v) => (v !== d.masking ? mask(v) : null)),
    h("div", { style: "margin-top:10px" }, switchRow("Чистый WG", "пускать и обычный WireGuard без обфускатора (iOS) — его DPI видит",
      d.clean, (on) => call("wgobf", "clean", on ? "1" : "0"))),
    h("h2", {}, "Клиенты"),
    btn("➕ Добавить клиента", () => go("/wgobf/add"), "btn-primary btn-block"),
    h("div", { style: "margin-top:10px" }, rows.length ? rows.map((c) => {
      const enc = encodeURIComponent(c.name);
      return ecard({ state: wgobfOnline(c) ? "on" : "", name: c.name, attrs: { "data-name": c.name },
        onopen: () => go(`/wgobf/client/${enc}`), right: wgobfSeen(c),
        lines: [c.ip + (c.rx || c.tx ? ` · ↓ ${fmtBytes(c.rx)} ↑ ${fmtBytes(c.tx)}` : "")],
        acts: [act("file-text", "Комплект", () => go(`/wgobf/client/${enc}`)), act(WEB ? "download" : "send", TO("В чат", "Файл"), (b) => sendWgobf(b, c.name, "wgobf")),
          act("trash-2", "Удалить", (b) => quickAsk(b, `Удалить клиента ${c.name}?`, "Клиент удалён", ["wgobf", "del", c.name]), "bad")] });
    }) : h("div", { class: "card empty" }, "Клиентов нет")),
    btn("🗑 Удалить обфускатор", (b) => quickAsk(b, "Удалить WG + обфускатор со всеми его клиентами? AWG не затрагивается; "
      + "архив на всякий случай ляжет в ~/awg_backup.", "Обфускатор удалён", ["wgobf", "remove"]), "btn-danger btn-block"));
});

route(/^\/wgobf\/add$/, async (ctx) => {
  const rows = (await call("wgobf", "clients")) || [];
  const taken = new Set(rows.map((c) => c.name));
  const free = () => { let n = 1; while (taken.has("client" + n)) n++; return "client" + n; };
  const name = h("input", { placeholder: "keenetic_home", maxlength: 32, autocapitalize: "off", autocomplete: "off" });
  ctx.put(title("Новый клиент"), hint("Клиент WG + обфускатор — комплект со ссылкой для Keenetic и конфигами."),
    h("label", {}, "Имя — латиница, цифры, _ и -, до 32"),
    h("div", { class: "row" }, name, h("button", { onclick: () => { name.value = free(); } }, icon("dices"))),
    btn("Создать", (b) => {
      const v = name.value.trim() || free();
      if (!/^[A-Za-z0-9_-]{1,32}$/.test(v)) return fail(new Error("Имя: латиница, цифры, _ и -, до 32"));
      if (taken.has(v)) return fail(new Error(`Имя ${v} уже занято`));
      return busy(b, async () => {
        await call("wgobf", "add", v);
        haptic(); toast("Клиент создан");
        replace(`/wgobf/client/${encodeURIComponent(v)}`);
      });
    }, "btn-primary btn-block"));
});

route(/^\/wgobf\/client\/([^/]+)$/, async (ctx, name) => {
  // Комплект не собрался — статус и мониторинг всё равно на экране, ошибка — плашкой
  const [d, rows] = await Promise.all([post("/api/wgobf/bundle", { name }).catch((e) => ({ error: e.message })),
    call("wgobf", "clients").catch(() => [])]);
  const c = (rows || []).find((x) => x.name === name);
  if (d.error && !c) throw new Error(d.error);
  ctx.put(title(name, pill("обфускатор", "accent")),
    c ? h("div", { class: "card", "data-name": "wgobf-status" }, kv("Статус", wgobfSeen(c)), kv("Адрес", c.ip),
      kv("Трафик с запуска", `↓ ${fmtBytes(c.rx)} · ↑ ${fmtBytes(c.tx)}`)) : null,
    d.error ? h("div", { class: "card warn small" }, "Комплект клиента не собрался: " + d.error) : null,
    switchRow("Мониторинг", "сообщу в чат, когда клиент пропал (5 минут без связи) и когда вернулся", !!d.mon,
      (on) => post("/api/wgobf/mon", { name, on })),
    h("div", { class: "pair" },
      btn(TO("✉️ Всё в чат", "⬇️ Файл .conf"), (b) => sendWgobf(b, name, "wgobf"), "btn-primary"),
      btn("📦 Архив Linux", (b) => sendWgobf(b, name, "wgobf_zip"))),
    // Ссылка phobos:// — длинный base64: на экране начало, целиком — копированием
    d.link ? [h("h2", {}, "Ссылка для Keenetic"),
      h("div", { class: "card" }, h("div", { class: "mono small", style: "overflow-wrap:anywhere" },
        d.link.length > 90 ? d.link.slice(0, 90) + "…" : d.link),
      h("div", { class: "muted small", style: "margin-top:4px" }, `AWG Manager → Новый туннель → «Phobos» → нижнее поле `
        + `«Или конфиг .conf … / ссылка phobos://». Верхнее «Ссылка установки Phobos» — пустым: оно только для http(s)-ссылок `
        + `панели Phobos · ${d.link.length} символов`)),
      copyBtn("Скопировать ссылку", d.link, "btn-primary btn-block")] : null,
    d.conf ? [h("h2", {}, "Конфиг"), hint("WireGuard и секция [instance] обфускатора — тот же файл .conf, что " + TO("приходит в чат.", "скачивается кнопкой.")),
      h("pre", {}, d.conf), copyBtn("Скопировать конфиг", d.conf)] : null,
    d.direct ? [h("h2", {}, "Чистый WireGuard"), hint("Без обфускатора — для iOS и обычного WireGuard. DPI его видит."),
      d.png ? h("img", { class: "qr", src: "data:image/png;base64," + d.png, alt: "QR" }) : null,
      copyBtn("Скопировать конфиг", d.direct)] : null,
    btn("🗑 Удалить клиента", (b) => quickAsk(b, `Удалить клиента ${name}?`, "Клиент удалён", ["wgobf", "del", name],
      () => backWith((p) => (/^\/wgobf\/client\//.test(p) ? "/wgobf" : null))), "btn-danger btn-block"));
});

// ── Бот ───────────────────────────────────────────────────
// Бот перезапускается (прокси, перезапуск): Mini App живёт в процессе бота и ждёт
// новый процесс — у него другое время старта. Веб-панель — отдельный процесс:
// её /api/me всегда отдаёт своё время старта, поэтому она ждёт, пока служба бота снова станет active
async function botRestarting(started, what, running = true) {
  // Остановленного бота awg2 не перезапускает (bot_restart) — ждать нечего
  if (WEB && !running) {
    toast(`${what}. Бот остановлен — изменения вступят в силу, когда он запустится`, 5000);
    render();
    return;
  }
  toast(`${what} — бот перезапускается…`, 8000);
  const until = Date.now() + 120e3;
  let back = false;
  // awg2 откладывает рестарт на 2 с — раньше статус показал бы ещё старый процесс
  if (WEB) await new Promise((ok) => setTimeout(ok, 4000));
  while (!back && Date.now() < until) {
    await new Promise((ok) => setTimeout(ok, WEB ? 3000 : 2000));
    try {
      back = WEB ? !!((await call("bot", "status")) || {}).active : (await post("/api/me")).started !== started;
    } catch (_) { /* ещё не поднялся */ }
  }
  toast(back ? "✅ Бот снова на связи" : "Бот не ответил за 2 минуты — открой панель заново", 4000);
  if (back) render();
}
// Сервер панели переезжает или выключается: дальше — только кнопкой «Меню»
function panelMoved(ctx, head, text) {
  post("/api/bot/webapp/restart").catch(() => {});
  ctx.put(title(head), h("div", { class: "card" }, text),
    hint(WEB ? "Mini App в Telegram откроется по новому адресу: закрой её и открой снова кнопкой «Меню» в чате с ботом."
      : "Закрой панель и открой её снова кнопкой «Меню» в чате с ботом."),
    tg ? btn("Закрыть панель", () => (tg.close ? tg.close() : null), "btn-primary btn-block") : null);
}

route(/^\/bot$/, async (ctx) => {
  if (WEB && !(S.me && S.me.tg_bot)) {
    return ctx.put(title("Бот"), h("div", { class: "card empty" }, "Telegram-бот не установлен"),
      hint("Бот — те же разделы кнопками в Telegram, уведомления о сервере и автобэкапы в чат. "
        + "Поставить: sudo awg2 → Telegram-бот → Установить."));
  }
  const [d, me] = await Promise.all([post("/api/bot/info"), post("/api/me")]);
  const w = d.webapp || {}, ic = d.icons || {};
  ctx.put(title("Бот"),
    ecard({ state: d.active === false ? "bad" : "on", name: "Telegram-бот", attrs: { "data-name": "bot" },
      right: d.active === false ? pill("остановлен", "bad") : pill("работает", "ok"),
      meta: [tag("бот " + d.version, "accent"), tag(d.proxy ? "через прокси" : "напрямую", "", "network"),
        tag(WEB ? "веб-панель" : d.owner ? "ты — владелец" : "ты — админ")],
      lines: [d.proxy || null],
      acts: [act("refresh-cw", "Рестарт", async (b) => {
        if (!await confirmTg("Перезапустить бота? Панель подождёт и продолжит работу.")) return;
        await busy(b, async () => { await call("bot", "restart"); await botRestarting(me.started, "Перезапуск", d.active !== false); });
      }), act("circle-arrow-up", "Обновить", () => updateBot(ctx)), act("file-text", "Журнал", () => go("/log/bot"))] }),
    statGrid([
      [`${d.owners} + ${d.invited}`, "Админы", "владельцы + приглашённые", d.owner ? () => go("/bot/admins") : null],
      [ic.active ? `${ic.count}/${ic.total}` : "выкл", "Иконки", ic.active ? ic.pack : "обычные эмодзи", d.owner ? () => go("/bot/look") : null],
      [w.running ? "работает" : "выкл", "Mini App", w.running ? `порт ${w.port}` : (w.error || "—"), d.owner ? () => go("/bot/app") : null],
      [d.proxy ? "прокси" : "напрямую", "До Telegram", d.proxy ? "через прокси" : "без прокси", () => go("/bot/proxy")],
    ]),
    h("div", { class: "card list" },
      WEB ? null : menuItem("💬 Меню бота в чат", "главное меню — новым сообщением внизу чата", menuToChat),
      menuItem("🌐 Прокси до Telegram", d.proxy || "нет — напрямую", () => go("/bot/proxy")),
      d.owner ? menuItem("👮 Админы", `владельцев ${d.owners}, приглашённых ${d.invited}`, () => go("/bot/admins")) : null,
      d.owner && !WEB ? menuItem("🎨 Оформление", "иконки custom emoji в боте", () => go("/bot/look")) : null,
      d.owner ? menuItem("📱 Mini App и сертификат", w.running ? w.url : "не запущена", () => go("/bot/app")) : null,
      d.owner ? menuItem("🔔 Уведомления", "awg0, перезагрузка, ядро, новая версия, диск", () => go("/bot/alerts")) : null),
    d.owner ? btn("🗑 Удалить бота", async () => {
      if (!await confirmTg("Удалить бота: службу, код и конфиг с токеном? AWG не затрагивается, конфиг копируется в бэкапы.")) return;
      if (!await confirmTg("Точно удалить? Панель и бот перестанут работать.")) return;
      await busy(null, async () => {
        await post("/api/job", { args: ["bot", "uninstall"] });
        ctx.put(title("Бот удаляется"), h("div", { class: "card" }, "Задача удаления запущена на сервере. Панель сейчас отключится."),
          hint("Вернуть бота: sudo awg2 → Telegram-бот → Установить."));
      });
    }, "btn-danger btn-block") : null);
});

const ALERT_HINTS = {
  iface: "две проверки подряд без awg0 — и когда он вернётся, с временем простоя",
  reboot: "сервер загрузился заново: время работы и поднялся ли awg0",
  update: "вышла новая версия AWG Toolza — один раз на версию",
  kernel: "apt поставил ядро, под которое модуль AWG не собрался",
  cert: "сертификат панели скоро истечёт — продление не сработало",
  disk: "место на диске почти кончилось",
};
route(/^\/bot\/alerts$/, async (ctx) => {
  const a = await post("/api/alerts");
  ctx.put(title("🔔 Уведомления"),
    hint(`Бот пишет владельцам и админам, когда с сервером что-то случилось; проверка — раз в ${Math.max(1, Math.round(a.interval / 60))} мин. Каждое событие — один раз.`),
    a.kinds.map((k) => switchRow(k.label, ALERT_HINTS[k.id] || "", k.on, async (on) => {
      if (!a.owner) throw new Error("Уведомления настраивает только владелец");
      await post("/api/alerts", { kind: k.id, on });
    })),
    hint("Сроки и лимиты трафика клиентов сообщает таймер awg2 — эти уведомления приходят всегда, даже когда бот остановлен."));
});

route(/^\/bot\/proxy$/, async (ctx) => {
  const [d, me] = await Promise.all([post("/api/bot/info"), post("/api/me")]);
  const url = h("input", { placeholder: "socks5://логин:пароль@1.2.3.4:1080", autocapitalize: "off", autocomplete: "off" });
  const cands = h("div");
  // Проверка не прошла — спросить, сохранить ли всё равно
  async function apply(b, v) {
    let force = false;
    for (;;) {
      if (b) b.disabled = true;
      try {
        await callR(["bot", "proxy", "set", v, ...(force ? ["force"] : [])], { timeout: 180 });
        break;
      } catch (e) {
        if (b) b.disabled = false;
        if (force || !await confirmTg(`${e.message}\n\nСохранить адрес всё равно?`)) return fail(e);
        force = true;
      }
    }
    url.value = "";
    await botRestarting(me.started, "Прокси сохранён", d.active !== false);
  }
  ctx.put(title("Прокси до Telegram"),
    h("div", { class: "card" }, kv("Сейчас", h("span", { class: "mono" }, d.proxy || "нет — напрямую")),
      h("div", { class: "muted small" }, "Нужен, если Telegram у хостера заблокирован: SOCKS5/HTTP-прокси или туннель этого сервера.")),
    btn("🔎 Найти на сервере", (b) => busy(b, async () => {
      toast("Ищу прокси и туннели, проверяю Telegram через каждый…", 6000);
      const rows = (await call("bot", "proxy", "candidates")) || [];
      cands.replaceChildren(rows.length ? h("div", { class: "card list" }, rows.map((r) =>
        h("div", { class: "item", onclick: (ev) => apply(null, r.url) },
          h("div", { class: "dot " + (r.ok ? "on" : "bad") }),
          h("div", { class: "main" }, h("div", { class: "title" }, r.label.split(" — ")[0]), h("div", { class: "sub mono" }, r.url)),
          h("div", { class: "side" }, icon("chevron-right")))))
        : h("div", { class: "card empty" }, "Подходящих выходов на сервере нет — введи адрес вручную"));
    }), "btn-block"),
    cands,
    h("label", {}, "Или адрес: схема://[логин:пароль@]хост:порт — http, https, socks4, socks5, socks5h, iface://warp0"),
    url,
    btn("💾 Сохранить", (b) => {
      const v = url.value.replace(/\s/g, "");
      if (!/^(https?|socks4|socks5h?|iface):\/\/\S+$/.test(v)) return fail(new Error("Нужна схема: http, https, socks4, socks5, socks5h или iface"));
      return apply(b, v);
    }, "btn-primary btn-block"),
    d.proxy ? h("div", { class: "pair", style: "margin-top:8px" },
      btn("🩺 Проверить", (b) => busy(b, async () => { await call("bot", "proxy", "check"); haptic(); toast("✅ Через прокси Telegram отвечает"); })),
      btn("🗑 Убрать", async (b) => {
        if (!await confirmTg("Убрать прокси? Бот пойдёт к Telegram напрямую.")) return;
        await busy(b, async () => { await call("bot", "proxy", "clear"); await botRestarting(me.started, "Прокси убран", d.active !== false); });
      }, "btn-danger")) : null,
    hint("После сохранения бот перезапустится — панель дождётся его сама."));
});

route(/^\/bot\/admins$/, async (ctx) => {
  const d = await post("/api/bot/info");
  if (!d.owner) return ctx.put(title("Админы"), h("div", { class: "card empty" }, "Список админов правит только владелец"));
  const a = d.admins || { owners: [], invited: [], pending: 0 };
  async function invite(b) {
    const r = await busy(b, () => post("/api/bot/invite"));
    if (!r) return;
    const box = h("div", { class: "sheet" });
    let close = null;
    const until = new Date(r.expires * 1000).toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });
    box.append(h("h3", {}, "Приглашение"),
      hint(`Одноразовая ссылка, сгорит в ${until}. Перешли тому, кому даёшь доступ.`),
      h("pre", {}, r.link),
      h("button", { onclick: () => copy(r.link) }, icon("copy"), "Скопировать"),
      h("button", { onclick: () => {
        const share = "https://t.me/share/url?url=" + encodeURIComponent(r.link);
        if (tg && tg.openTelegramLink) tg.openTelegramLink(share); else window.open(share, "_blank", "noopener");
      } }, icon("share-2"), "Переслать в Telegram"),
      hint("⚠️ Админ может всё, кроме управления списком админов: бот — это root на сервере."),
      h("button", { class: "btn-primary", onclick: () => close() }, "Готово"));
    // Закрыли — список приглашений обновляется; закрыт сменой экрана — обновлять нечего
    close = sheetOpen(box, (nav) => { if (!nav) render(); });
  }
  const who = (x) => (x.username ? "@" + x.username : String(x.uid));
  ctx.put(title("Админы"),
    h("h2", {}, "Владельцы"),
    h("div", { class: "card list" }, a.owners.map((uid) => h("div", { class: "item" }, h("div", { class: "ibox" }, icon("shield-check")),
      h("div", { class: "main" }, h("div", { class: "title mono" }, uid), h("div", { class: "sub" }, "ADMIN_ID в /etc/awg-bot.conf"))))),
    h("h2", {}, "Приглашённые"),
    a.invited.length ? h("div", { class: "card list" }, a.invited.map((x) => h("div", { class: "item", "data-uid": x.uid,
      onclick: () => quickAdmin(x) }, h("div", { class: "ibox" }, icon("user")),
    h("div", { class: "main" }, h("div", { class: "title" }, who(x)),
      h("div", { class: "sub mono" }, `${x.uid}${x.added_at ? " · с " + fmtTime(x.added_at) : ""}`)),
    h("div", { class: "side bad" }, icon("trash-2"))))) : h("div", { class: "card empty" }, "Приглашённых нет"),
    WEB ? hint("Пригласить админа — в Telegram-боте: ссылку-приглашение создаёт сам бот.")
      : btn("🙋 Пригласить", invite, "btn-primary btn-block"),
    a.pending ? btn(`🧯 Погасить приглашения: ${a.pending}`, (b) => busy(b, async () => {
      const r = await post("/api/bot/invites/revoke"); haptic(); toast(`Погашено приглашений: ${r.revoked}`); render();
    }), "btn-block") : null,
    hint("Приглашение — ссылка на 15 минут. Отозванный админ теряет доступ; выданные им конфиги продолжают работать."));
  async function quickAdmin(x) {
    if (!await confirmTg(`Отозвать доступ у ${who(x)}? Выданные им конфиги продолжат работать.`)) return;
    await busy(null, async () => {
      const r = await post("/api/bot/admin/del", { uid: x.uid }); haptic(); toast(r.message || "Доступ отозван"); render();
    });
  }
});

route(/^\/bot\/look$/, async (ctx) => {
  const d = await post("/api/bot/info");
  if (!d.owner) return ctx.put(title("Оформление"), h("div", { class: "card empty" }, "Оформление меняет только владелец"));
  const ic = d.icons || {};
  const pack = h("input", { placeholder: "t.me/addemoji/ИМЯ", autocapitalize: "off", autocomplete: "off" });
  const apply = (b, body) => busy(b, async () => {
    toast("Проверяю иконки — пробное сообщение в чате…", 5000);
    const r = await post("/api/bot/icons", body);
    haptic(r.active ? "success" : "error");
    toast(r.active ? `✅ Иконки включены: ${r.have.length} из ${r.have.length + r.miss.length}`
      : "❌ Telegram не показал иконки — нужен Telegram Premium у владельца бота или имя бота с Fragment", 5000);
    render();
  });
  ctx.put(title("Оформление"),
    ecard({ state: ic.active ? "on" : "", name: "Иконки в боте", right: pill(ic.active ? "включены" : "выключены", ic.active ? "ok" : ""),
      meta: [ic.pack ? tag(ic.pack, "accent", "palette") : tag("набор не выбран"), ic.count ? tag(`${ic.count} ${plural(ic.count, "иконка", "иконки", "иконок")}`) : null],
      lines: ["custom emoji вместо эмодзи в тексте и на кнопках"] }),
    hint("Иконки бот может показывать, только если у владельца бота (аккаунт, создавший "
      + "его в @BotFather) есть Telegram Premium или у бота имя с Fragment. Перестанут быть видны — бот сам вернётся к эмодзи."),
    btn(`📥 Набор ${ic.default || "TgAndroidIcons"}`, (b) => apply(b, { action: "pack", name: ic.default }), "btn-primary btn-block"),
    h("label", {}, "Свой набор — ссылка на набор эмодзи"), pack,
    btn("Применить набор", (b) => {
      const v = pack.value.trim();
      if (!v) return fail(new Error("Нужна ссылка вида t.me/addemoji/ИМЯ"));
      return apply(b, { action: "pack", name: v });
    }, "btn-block"),
    h("div", { class: "pair", style: "margin-top:8px" },
      ic.count && !ic.active ? btn("▶️ Включить", (b) => apply(b, { action: "on" })) : null,
      ic.active ? btn("⏹ Выключить", (b) => busy(b, async () => {
        await post("/api/bot/icons", { action: "off" }); haptic(); toast("Иконки выключены — снова обычные эмодзи"); render();
      })) : null),
    hint("Свои иконки по одной (custom emoji сообщением) — в боте: Бот → Оформление → Свои иконки."));
});

route(/^\/bot\/app$/, async (ctx) => {
  const [d, c] = await Promise.all([post("/api/bot/info"), call("cert", "status")]);
  if (!d.owner) return ctx.put(title("Mini App"), h("div", { class: "card empty" }, "Mini App настраивает только владелец"));
  const w = d.webapp || {};
  const dom = h("input", { placeholder: "panel.example.com", autocapitalize: "off", autocomplete: "off" });
  const port = h("input", { type: "number", min: 1, max: 65535, placeholder: String(w.port || 8443) });
  // После выпуска — перезапуск сервера Mini App: иначе при смене домен ↔ IP
  // адрес панели и кнопка «Меню» остаются старыми при новом сертификате.
  const issueJob = (head, args, after) => runJob(ctx, head, args, () => [
    hint(after), tg ? btn("Закрыть панель", () => (tg.close ? tg.close() : null), "btn-primary btn-block") : null])
    .then(() => post("/api/bot/webapp/restart").catch(() => {}));
  // Готовый сертификат сервера: выбрать из найденных и сослаться на него
  const useFound = async () => {
    const rows = (await call("cert", "find")) || [];
    if (!rows.length) return toast("Готовых сертификатов на этот сервер не нашлось", 3000);
    const pick = await sheet("📂 Готовые сертификаты сервера", rows.map((r) => ({
      label: `${r.name} · ${r.source} · до ${fmtTime(r.expires).split(",")[0]}`, value: r.cert })));
    if (!pick) return;
    await busy(null, async () => {
      await call("cert", "use", pick);
      panelMoved(ctx, "Готовый сертификат подключён", "Mini App переехала на него; продлевает его та программа, что выпустила.");
    });
  };
  // Порт 80 занят — выпуск с паузой службы или готовый сертификат
  const issue = async (head, args, after) => {
    if (!c.port80) return issueJob(head, args, after);
    const opts = [];
    if (c.port80_unit) opts.push({ label: `⏸ Останавливать ${c.port80_unit} на секунды выпуска и продления`, value: "pause" });
    if (c.found) opts.push({ label: `📂 Взять готовый сертификат (${c.found})`, value: "found" });
    if (!opts.length) return fail(new Error(`Порт 80 занят (${c.port80}), а службу не опознать — освободи порт на время выпуска`));
    const pick = await sheet(`Порт 80 занят (${c.port80})`, opts);
    if (pick === "pause") return issueJob(head, [...args, "pause"], after);
    if (pick === "found") return useFound();
  };
  const setPort = async (v) => {
    if (!await confirmTg(v === "off" ? "Выключить Mini App? Панель закроется, кнопка «Меню» станет обычной."
      : `Перенести панель на порт ${v}? Её придётся открыть заново кнопкой «Меню».`)) return;
    await busy(null, async () => {
      await call("bot", "webapp", "port", v);
      panelMoved(ctx, v === "off" ? "Mini App выключена" : "Панель переезжает", v === "off"
        ? "Сервер панели остановлен. Включить — в боте: Бот → Mini App → Порт." : `Новый адрес — порт ${v}.`);
    });
  };
  ctx.put(title("Mini App"),
    ecard({ state: w.running ? "on" : "bad", name: "Сервер панели", right: pill(w.running ? "работает" : "выключен", w.running ? "ok" : "bad"),
      meta: [tag("порт " + (w.port || "off"), "accent"), !c.installed ? tag("нет сертификата", "bad")
        : tag(c.kind === "external" ? "готовый · " + (c.source || "") : c.kind === "ip" ? "сертификат на IP" : "сертификат на домен", "ok", "lock")],
      lines: [w.url || w.error] }),
    c.installed ? statGrid([
      [c.name || "—", "Сертификат", c.kind === "external" ? "готовый, " + (c.source || "") : c.kind === "ip" ? "Let's Encrypt, IP" : "Let's Encrypt, домен"],
      [c.expires ? fmtTime(c.expires).split(",")[0] : "—", "Действует до", c.kind === "external" ? "продлевает " + (c.source || "его программа")
        : c.renew ? "продлевается сам" : "⚠️ таймер продления не работает"],
    ]) : null,
    c.port80 ? h("div", { class: "card warn small" }, `Порт 80 занят (${c.port80}) — выпуск только с паузой службы`
      + (c.found ? ` или готовым сертификатом (${c.found}).` : ".")) : null,
    h("h2", {}, "Сертификат"),
    c.found ? btn(`📂 Готовый сертификат сервера (${c.found})`, () => useFound(), "btn-block") : null,
    btn(`🔐 На IP ${c.ip || ""}`, () => issue("Сертификат на IP", ["cert", "issue", "ip"],
      "Сертификат выпущен. Сервер панели подхватит его сам; если панель перестанет отвечать — открой её заново."), "btn-block"),
    h("label", {}, "Или на домен — A-запись должна указывать на этот сервер"), dom,
    btn("🌍 Выпустить на домен", () => {
      const v = dom.value.trim().toLowerCase();
      if (!DOMAIN_RE.test(v)) return fail(new Error("Нужен домен вида panel.example.com"));
      return issue(`Сертификат на ${v}`, ["cert", "issue", "domain", v], `Сертификат на ${v} выпущен. Панель переезжает на домен — `
        + "закрой её и открой снова кнопкой «Меню».");
    }, "btn-block"),
    hint("На IP — сертификат живёт ~6 дней и продлевается сам; для проверки нужен свободный и открытый порт 80. На домен — 90 дней. "
      + "Готовый — уже выпущенный Caddy, certbot, Marzban, 3x-ui или nginx: порт 80 не нужен."),
    h("h2", {}, "Порт"),
    h("div", { class: "row" }, port, btn("OK", () => {
      const v = port.value.trim();
      if (!validPort(v) || v === "80") return fail(new Error("Порт — число 1-65535, кроме 80"));
      return setPort(v);
    })),
    h("div", { class: "chips" }, ["8443", "443"].map((v) => h("button", { class: "chip", onclick: () => setPort(v) }, v)),
      h("button", { class: "chip", onclick: () => setPort("off") }, "выключить")),
    hint("443 — адрес без номера порта, если его не занял Xray. 80 занят проверкой сертификата."),
    c.installed ? btn("🗑 Удалить сертификат", async (b) => {
      if (!await confirmTg("Удалить сертификат? Mini App перестанет открываться, продление остановится.")) return;
      await busy(b, async () => {
        await call("cert", "remove");
        panelMoved(ctx, "Сертификат удалён", "Mini App выключена — без сертификата Telegram её не откроет.");
      });
    }, "btn-danger btn-block") : null);
});

// ── Журналы служб ─────────────────────────────────────────
const LOGS = { manager: "awg2 — действия", install: "Компоненты", module: "Сборка модуля", awg: "awg0 (awg-quick)",
  expire: "Сроки клиентов", warp: "WARP", "warp-health": "WARP health-check", usque: "usque (WARP MASQUE)", xray: "Xray",
  "xray-routing": "Маршруты Xray", tun2socks: "tun2socks", exits: "Exit-ноды", cascade: "Каскад", dns: "dnscrypt-proxy",
  "dns-health": "DNS health-check", wgobf: "WG + обфускатор", bot: "Telegram-бот", antiscan: "Антисканер" };

route(/^\/log\/([a-z0-9-]+)$/, async (ctx, name) => {
  const r = await callR(["log", name, "150"]);
  const pre = h("pre", { style: "max-height:70vh" }, (r.log || "").trim() || "пусто");
  ctx.put(title("📜 " + (LOGS[name] || name)), pre, btn("🔄 Обновить", () => render(), "btn-block"));
  pre.scrollTop = pre.scrollHeight;
});

// ── Веб-панель: вход и выход ──────────────────────────────
function showLogin(err = "") {
  token++;                       // недорисованный экран не затрёт форму входа своей ошибкой
  S.me = null;
  // Экран, прерванный на перезагрузке, сам «reloading» уже не снимет (он не live) —
  // иначе форма входа приглушена и не нажимается. Снимки прежней сессии — тоже долой
  root.classList.remove("reloading");
  delete root.dataset.path;
  SNAP.clear();
  closeDrawer(); closeOverlays(); closePal();
  drawTop();
  const user = h("input", { autocomplete: "username", placeholder: "Логин", maxlength: "64", "aria-label": "Логин", required: "" });
  const pass = h("input", { type: "password", autocomplete: "current-password", placeholder: "Пароль", maxlength: "256",
    "aria-label": "Пароль", required: "" });
  const msg = h("div", { class: "bad small", style: "min-height:18px;margin:6px 2px" }, err);
  const enter = h("button", { class: "btn-primary btn-block", type: "submit" }, icon("lock"), "Войти");
  const form = h("form", { class: "card login", onsubmit: async (ev) => {
    ev.preventDefault();
    enter.disabled = true;
    msg.textContent = "";
    try {
      const r = await fetch(url("/api/login"), { method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ user: user.value.trim(), password: pass.value }) })
        .catch(() => { throw new Error("Нет связи с сервером"); });
      const d = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(d.error || `HTTP ${r.status}`);
      pass.value = "";
      if (location.hash && location.hash !== "#/") history.replaceState(null, "", "#/");
      await webStart();
    } catch (e) {
      msg.textContent = e.message;
      pass.select();
    } finally { enter.disabled = false; }
  } },
  h("img", { class: "logo tz big", src: tzIcon(true), alt: "" }),
  h("h3", {}, "AWG Toolza"),
  h("div", { class: "muted small", style: "margin-bottom:14px" }, "Веб-панель сервера"),
  user, pass, msg, enter);
  root.replaceChildren(form);
  user.focus();
}

async function logout() {
  try { await post("/api/logout"); } catch (_) { /* уже вышли */ }
  showLogin();
}

// Сводка сервера для шапки: версия, канал, обновление, имя и адрес сервера
function refreshStatus() {
  const gen = chanGen;
  return post("/api/status").then((d) => { setStatus(d, gen); drawTop(); }).catch(() => {});
}

async function webStart() {
  try { S.me = await post("/api/me"); } catch (_) { return; }      // 401 — экран входа уже на месте
  drawTop();                                                     // лента и шапка — после входа
  render();
  if (curPath() !== "/") refreshStatus();                       // обзор грузит сводку сам
}

const WEB_EVENTS = { LOGIN: ["вход", "ok"], FAIL: ["неверный пароль", "bad"], LOCK: ["блокировка", "bad"],
  PASSWD: ["пароль сменён", "warn"], SESSIONS: ["сессии завершены", "warn"], CSRF: ["чужой сайт", "bad"] };
route(/^\/account$/, async (ctx) => {
  if (!WEB) return ctx.put(title("Аккаунт"), h("div", { class: "card empty" }, "Есть только в веб-панели"));
  const d = await post("/api/web/account");
  const old = h("input", { type: "password", autocomplete: "current-password", placeholder: "Текущий пароль" });
  const nw = h("input", { type: "password", autocomplete: "new-password", placeholder: "Новый — от 10 символов" });
  const nw2 = h("input", { type: "password", autocomplete: "new-password", placeholder: "Новый ещё раз" });
  const ago = (ts) => fmtDur(Date.now() / 1000 - ts) + " назад";
  ctx.put(title("Аккаунт", pill("веб-панель", "accent")),
    h("div", { class: "card" }, kv("Логин", d.user), kv("Адрес", h("span", { class: "mono" }, `${location.host}${d.base}`)),
      kv("Сертификат", d.cert === "self" ? h("span", { class: "warn" }, "самоподписанный") : "Тулзы (Let's Encrypt или готовый)")),
    d.cert === "self" ? hint("Браузер предупреждает о самоподписанном сертификате — соединение всё равно шифруется. "
      + "Настоящий: sudo awg2 → Веб-панель → Сертификат (на IP — Let's Encrypt, нужен свободный порт 80).") : null,
    h("h2", {}, "Сменить пароль"),
    h("div", { class: "card" }, old, nw, nw2,
      enterTo(btn("🔑 Сменить пароль", (b) => busy(b, async () => {
        if (nw.value !== nw2.value) throw new Error("Новые пароли не совпадают");
        const r = await post("/api/web/password", { old: old.value, new: nw.value });
        old.value = nw.value = nw2.value = "";
        haptic(); toast(`✅ Пароль сменён${r.dropped ? `, другие сессии завершены: ${r.dropped}` : ""}`, 4000); render();
      }), "btn-primary btn-block"), old, nw, nw2)),
    hint("Пароль хранится на сервере только хешем (scrypt). Забыли — sudo awg2 → Веб-панель → Сменить пароль."),
    h("h2", {}, "Сессии"),
    h("div", { class: "card list" }, (d.sessions || []).map((x) => h("div", { class: "item" },
      h("div", { class: "ibox" }, icon(x.me ? "check" : "user")),
      h("div", { class: "main" }, h("div", { class: "title mono" }, x.ip + (x.me ? " · эта" : "")),
        h("div", { class: "sub" }, `${x.ua || "браузер"} · вход ${ago(x.created)}, активна ${ago(x.seen)}`))))),
    (d.sessions || []).length > 1 ? btn("🚪 Завершить остальные сессии", (b) => busy(b, async () => {
      const r = await post("/api/web/sessions/drop"); haptic(); toast(`Завершено: ${r.dropped}`); render();
    }), "btn-block") : null,
    h("h2", {}, "Последние события"),
    (d.log || []).length ? h("div", { class: "card list" }, d.log.map((line) => {
      const [date, time, ev, ip, ...rest] = line.split(" ");
      const [label, cls] = WEB_EVENTS[ev] || [ev, ""];
      return h("div", { class: "item" }, h("div", { class: "main" },
        h("div", { class: "title" }, pill(label, cls), " ", h("span", { class: "mono" }, ip || "")),
        h("div", { class: "sub" }, `${date || ""} ${time || ""} ${rest.join(" ")}`)));
    })) : h("div", { class: "card empty" }, "Событий пока нет"),
    btn("🚪 Выйти", () => logout(), "btn-block"));
});

// ── Старт ─────────────────────────────────────────────────
if (tg) {
  tg.ready();
  tg.expand();
  if (tg.BackButton) tg.BackButton.onClick(back);
  // Тема Telegram сменилась, а своей пользователь не выбирал — следуем за ней
  if (tg.onEvent) tg.onEvent("themeChanged", () => { if (LOOK.mode === "auto") { applyLook(); drawTop(); } });
}
if (window.matchMedia) {
  const mq = matchMedia("(prefers-color-scheme: light)");
  if (mq.addEventListener) mq.addEventListener("change", () => { if (WEB && LOOK.mode === "auto") { applyLook(); drawTop(); } });
}
favRefresh();
window.addEventListener("hashchange", render);
// Окно стало шире или уже: лента ↔ нижняя панель, таблица ↔ карточки
if (WEB && DESK_MQ && DESK_MQ.addEventListener) {
  let mqT = 0;
  DESK_MQ.addEventListener("change", () => {
    clearTimeout(mqT);
    mqT = setTimeout(() => { if (S.me && railOn() !== document.body.classList.contains("rail-on")) { drawTop(); render(); } }, 200);
  });
}
// Ширина перешла 380/720px (поворот телефона, окно Telegram Desktop): название в шапке
// выбирает размер при отрисовке — без этого после поворота оно остаётся крупным и теснит флаг
if (window.matchMedia) {
  let lkT = 0;
  const lkRedraw = () => {
    clearTimeout(lkT);
    lkT = setTimeout(() => {
      // Окно «О сервере» привязано к прежнему флагу и виду (лист/выпадающее) — закрыть до перерисовки
      const o = document.querySelector(".sinfo");
      if (o && o.parentNode && o.parentNode.close) o.parentNode.close();
      drawTop();
    }, 150);
  };
  ["(max-width: 380px)", "(max-width: 720px)"].forEach((q) => {
    const m = matchMedia(q);
    if (m.addEventListener) m.addEventListener("change", lkRedraw); else if (m.addListener) m.addListener(lkRedraw);
  });
}
drawTop();
window.AWG_STARTED = true;      // icons.js: старт прошёл — его отчёт об ошибке запуска больше не нужен
// Telegram Desktop для Windows без Microsoft Edge WebView2 Runtime открывает
// панель в старом Edge 18: вид упрощён. Подсказать, как вернуть современный
// движок (закрыл — до завтра не показываем)
const WV2_URL = "https://developer.microsoft.com/ru-ru/microsoft-edge/webview2/consumer";
if (tg && tg.initData && /Edge\/1\d\./.test(navigator.userAgent) && pref("wv2", "") !== new Date().toDateString()) {
  const bar = h("div", { class: "card warn wv2", style: "margin:10px 14px 0" },
    "Telegram открыл панель в старом движке Edge — вид упрощён. Поставь Microsoft Edge WebView2 Runtime и перезапусти Telegram: "
    + "панель будет как на телефоне. ",
    h("a", { href: WV2_URL, onclick: (ev) => { ev.preventDefault(); if (tg.openLink) tg.openLink(WV2_URL); else window.open(WV2_URL, "_blank", "noopener"); } },
      "Скачать WebView2"),
    " · ",
    h("a", { href: "#", onclick: (ev) => { ev.preventDefault(); setPref("wv2", new Date().toDateString()); bar.remove(); } }, "Скрыть"));
  document.body.insertBefore(bar, root);
}
if (WEB) {
  webStart();
} else if (!tg || !tg.initData) {
  // Адрес открыли в браузере: панель живёт в Telegram — кнопка открыть его.
  // Имени бота здесь нет: без подписи страница о сервере не говорит ничего
  root.replaceChildren(h("div", { class: "card open-tg" },
    h("img", { class: "logo tz big", src: tzIcon(true), alt: "" }),
    h("h3", {}, "Панель открывается в Telegram"),
    h("div", { class: "muted" }, "В чате с ботом — кнопка «Меню» слева от поля ввода."),
    h("a", { class: "btn btn-primary btn-block", href: "tg://" }, icon("send"), "Открыть Telegram"),
    h("a", { class: "muted small", href: "https://web.telegram.org/", target: "_blank", rel: "noopener" }, "или Telegram Web")));
} else {
  render();
  // Версия и сервер в шапке — для экранов, открытых не с обзора
  if (curPath() !== "/") refreshStatus();
}
