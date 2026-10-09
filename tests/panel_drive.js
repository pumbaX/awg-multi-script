const { chromium } = require("playwright");
const fs = require("fs");
const say = (...a) => fs.appendFileSync(process.argv[4] + "/run.log", a.join(" ") + "\n");
const [port, initData, out, theme, profile, sandboxRoot] = process.argv.slice(2);
(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await ctx.route(/telegram\.org/, (r) => r.abort());
  await ctx.addInitScript(({ initData, theme }) => {
    const noop = () => {};
    window.__log = [];
    window.Telegram = { WebApp: {
      initData, colorScheme: theme, ready: noop, expand: noop, onEvent: noop, close: () => window.__log.push("close"),
      BackButton: { show: () => window.__log.push("back:show"), hide: () => window.__log.push("back:hide"), onClick: (f) => { window.__back = f; } },
      HapticFeedback: { notificationOccurred: (t) => window.__log.push("haptic:" + t) },
      showConfirm: (t, cb) => { window.__log.push("confirm:" + t); cb(true); },
      showAlert: (t) => { window.__log.push("alert:" + t); },
    } };
  }, { initData, theme });
  const page = await ctx.newPage();
  page.setDefaultTimeout(15000);
  const errors = [];
  page.on("pageerror", (e) => errors.push("pageerror: " + e));
  // Адрес упавшего запроса — в сообщении: «Failed to load resource» сам его не называет
  page.on("console", (m) => { if (m.type() === "error" && !/telegram\.org|ERR_FAILED/.test(m.text()))
    errors.push("console: " + m.text() + ((m.location() || {}).url ? " " + m.location().url : "")); });
  const base = `https://127.0.0.1:${port}/`;
  const shot = async (name) => { await page.waitForTimeout(500); await page.screenshot({ path: `${out}/${name}.png`, fullPage: true }); };
  const noNull = async () => {
    const bad = await page.evaluate(() => [...document.querySelectorAll("#app, #app *")].some((el) =>
      [...el.childNodes].some((n) => n.nodeType === 3 && /^(null|undefined|false)$/.test(n.textContent.trim()))));
    if (bad) throw new Error("на экране текст null/undefined");
  };
  // Тот же адрес браузер навигацией не считает — тогда перезагружаем страницу
  const nav = async (hash, sel = "h1") => {
    if (page.url() === base + "#" + hash) await page.reload({ waitUntil: "domcontentloaded" });
    else await page.goto(base + "#" + hash, { waitUntil: "domcontentloaded" });
    await page.waitForSelector(sel); await page.waitForTimeout(300); await noNull();
  };
  // Подсказка прошлого шага не должна сойти за итог этого
  const step = async (name, fn) => {
    await page.evaluate(() => document.querySelectorAll(".toast").forEach((t) => t.remove()));
    try { await fn(); await noNull(); say("OK  ", name); } catch (e) { say("FAIL", name, String(e).split("\n")[0]); errors.push(name + ": " + e); }
  };

  const alerts = async () => (await page.evaluate(() => window.__log)).filter((l) => l.startsWith("alert:"));
  const expectAlert = async (text, fn) => {
    const before = (await alerts()).length;
    await fn();
    await page.waitForTimeout(300);
    const got = (await alerts()).slice(before);
    if (!got.some((a) => a.includes(text))) throw new Error(`ждали окно «${text}», было: ${JSON.stringify(got)}`);
    // Ожидаемые окна — не ошибки: из итогового списка их убираем
    await page.evaluate(() => { window.__log = window.__log.filter((l) => !l.startsWith("alert:")); });
  };

  await step("обзор", async () => {
    await nav("/", ".head h1");
    const t = await page.evaluate(() => document.documentElement.dataset.theme);
    if (t !== theme) throw new Error(`тема ${t}, а Telegram — ${theme}`);
    await page.waitForSelector(".top .lockup");
    await page.waitForSelector(".top .lock img");                    // знак в шапке — на телефоне и в Mini App
    if (/beta/.test(await page.getAttribute(".top .lockup", "aria-label"))) throw new Error("пометка «бета» на стабильном канале");
    if (await page.locator("#tabbar a").count() !== 5) throw new Error("ждали нижнюю панель: 4 раздела и «Ещё»");
    if (!await page.evaluate(() => window.AWG_STARTED) || await page.locator(".boot-fail").count()) throw new Error("старт не отмечен");
    await shot("01-home");
  });

  await step("шапка: флаг страны сервера, «О сервере» — по нажатию на флаг", async () => {
    await nav("/", ".head h1");
    const nl = profile !== "none", box = "[data-name=server-info]";
    if (nl) {
      if (await page.getAttribute(".top .cflag svg.flag", "aria-label") !== "Нидерланды") throw new Error("нет флага Нидерландов");
    } else await page.waitForSelector(".top .cflag .cc svg");          // страна не известна — глобус
    if (await page.locator(".top .sib").count()) throw new Error("кнопка «i» лишняя — окно по флагу");
    // Подпись для чтения с экрана — как всплывающая: о сервере, страна и состояние
    const nm = await page.getAttribute(".top .cflag", "aria-label");
    if (!/^О сервере · .*(awg0|сервер не создан)/.test(nm) || nm !== await page.getAttribute(".top .cflag", "title")) throw new Error("подпись флага: " + nm);
    await page.click(".top .cflag");
    await page.waitForSelector(box);
    const t = await page.textContent(box);
    if (nl ? !/Нидерланды/.test(t) || !/awg0 (работает|не поднят)/.test(t) || !/AWG \d\.\d · \d+\/udp/.test(t)
      : !/Страна не определена/.test(t) || !/сервер не создан/.test(t)) throw new Error("окно «О сервере»: " + t);
    // Лист снизу — снимок экрана, а не всей страницы
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${out}/01b-server-info.png` });
    // Скрыть имя и адрес — тут же, окно остаётся открытым; и вернуть
    await page.click(`${box} button:has-text('Скрыть адрес')`);
    await page.waitForSelector(`${box} b.hid >> text=скрыто`);
    // Скрыт и порт: он часть адреса (как и на схеме маршрутов)
    if (nl && /\d+\/udp/.test(await page.textContent(box))) throw new Error("адрес скрыт, а порт в окне виден");
    await page.click(`${box} button:has-text('Показать адрес')`);
    await page.waitForSelector(`${box} button:has-text('Скрыть адрес')`);
    if (await page.locator(`${box} b.hid`).count()) throw new Error("адрес не вернулся");
    await page.keyboard.press("Escape");
    await page.waitForSelector(box, { state: "detached" });
    // Шапка при переключении перерисована — фокус всё равно возвращается на флаг, а не на страницу
    if (!await page.evaluate(() => document.activeElement === document.querySelector(".top .cflag"))) throw new Error("после Esc фокус не на флаге");
    // Узкий телефон: название не уходит под флаг
    const vp = page.viewportSize();
    await page.setViewportSize({ width: 360, height: vp.height });
    await page.waitForTimeout(200);
    const fit = await page.evaluate(() => {
      const l = document.querySelector(".top .lockup").getBoundingClientRect(), f = document.querySelector(".top .cflag").getBoundingClientRect();
      return { lockup: l.right, flag: f.left };
    });
    if (fit.lockup > fit.flag + 0.5) throw new Error("на 360 название заходит под флаг: " + JSON.stringify(fit));
    // Страна не из списка флагов (код буквами) и неизвестная (глобус): цель касания не уже 32px
    await page.setViewportSize(vp);
    await page.evaluate(() => { window.__st0 = S.status; });
    for (const cc of ["ZA", ""]) {
      const wd = await page.evaluate((cc) => { S.status = Object.assign({}, S.status, { country: cc }); drawTop();
        return document.querySelector(".top .cflag").getBoundingClientRect().width; }, cc);
      if (wd < 32) throw new Error(`флаг «${cc || "глобус"}» ${wd}px — уже цели касания 32px`);
    }
    await page.evaluate(() => { S.status = window.__st0; drawTop(); });
    // Узкое окно: «Показать адрес» не вылезает за кнопку
    await page.setViewportSize({ width: 320, height: vp.height });
    await page.waitForTimeout(300);          // шапка перерисовывается после смены ширины (и закрывает окно)
    await page.click(".top .cflag");
    await page.waitForSelector(box);
    await page.click(`${box} .seye`);
    const eye = await page.evaluate(() => { const b = document.querySelector(".sinfo .seye"); return { text: b.textContent, sw: b.scrollWidth, cw: b.clientWidth }; });
    if (eye.sw > eye.cw) throw new Error("на 320 «Показать адрес» шире кнопки: " + JSON.stringify(eye));
    await page.click(`${box} .seye`);
    await page.keyboard.press("Escape");
    await page.waitForSelector(box, { state: "detached" });
    await page.setViewportSize(vp);
    // Широкий экран: окно выпадает из флага
    await page.setViewportSize({ width: 1366, height: 900 });
    await page.waitForTimeout(300);          // шапка перерисовывается после смены ширины
    await page.click(".top .cflag");
    await page.waitForSelector(`${box}.pop`);
    const pos = await page.evaluate(() => {
      const b = document.querySelector(".top .cflag").getBoundingClientRect(), p = document.querySelector(".sinfo.pop").getBoundingClientRect();
      return { gap: p.top - b.bottom, left: Math.abs(p.left - b.left), w: p.width };
    });
    if (pos.gap < 0 || pos.gap > 20 || pos.left > 2) throw new Error("окно не под флагом: " + JSON.stringify(pos));
    await shot("01c-server-info-pc");
    await page.keyboard.press("Escape");
    await page.waitForSelector(box, { state: "detached" });
    // Окно открыто, а ширина перешла 720 (окно Telegram Desktop, поворот): шапка перерисовывается,
    // окно прежнего флага и вида закрывается, а не висит в стороне поверх экрана
    await page.click(".top .cflag");
    await page.waitForSelector(`${box}.pop`);
    await page.setViewportSize(vp);
    await page.waitForSelector(box, { state: "detached", timeout: 3000 })
      .catch(() => { throw new Error("после смены ширины окно «О сервере» осталось открытым"); });
    await page.waitForTimeout(300);
  });

  await step("уже открытый экран — сразу прежний вид, без «Загрузка…», свежий — следом", async () => {
    await nav("/", ".head h1");
    await nav("/clients", "#app .search input");
    const r = await page.evaluate(() => { location.hash = "/"; return new Promise((ok) => setTimeout(() =>
      ok({ spin: !!document.querySelector("#app > .spin"), h1: !!document.querySelector("#app .head h1") }), 30)); });
    if (r.spin || !r.h1) throw new Error("снимок не показан: " + JSON.stringify(r));
    await page.waitForSelector("#app:not(.reloading) .head h1");
  });

  await step("старый движок (Edge 18 в Telegram Desktop): без новых API панель работает", async () => {
    const p3 = await ctx.newPage();
    const errs = [];
    p3.on("pageerror", (e) => errs.push(String(e)));
    await p3.addInitScript(() => {
      window.AWG_FORCE_NOGAP = true;                // и обход gap у flex — как без его поддержки
      Object.defineProperty(navigator, "userAgent", { get: () => "Mozilla/5.0 (Windows NT 10.0; Win64; x64; WebView/3.0) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36 Edge/18.26300" });
      delete Array.prototype.flat; delete Object.fromEntries; delete String.prototype.trimStart; delete Blob.prototype.text;
      [Element, Document, DocumentFragment].forEach((C) => { delete C.prototype.replaceChildren; });
      const M = CanvasRenderingContext2D.prototype.measureText;
      CanvasRenderingContext2D.prototype.measureText = function (t) { return { width: M.call(this, t).width }; };
      const R = RegExp;
      window.RegExp = function (src, fl) {
        if (/\\p\{/.test(String(src)) && /u/.test(fl || "")) throw new SyntaxError("Invalid regular expression: invalid escape in unicode pattern");
        return new R(src, fl);
      };
      window.RegExp.prototype = R.prototype;
    });
    await p3.goto(base + "#/", { waitUntil: "domcontentloaded" });
    await p3.waitForSelector(".head h1");
    await p3.waitForSelector(".top .lockup text");
    if (await p3.locator(".boot-fail").count()) throw new Error(await p3.textContent(".boot-fail"));
    if (!await p3.locator("#tabbar a svg").count()) throw new Error("иконки нижней панели не нарисованы");
    if (!await p3.locator("[data-gapm]").count()) throw new Error("обход gap у flex не сработал");
    if (!await p3.locator(".wv2 a:has-text('Скачать WebView2')").count()) throw new Error("нет подсказки про WebView2");
    for (const [hash, sel] of [["#/clients", "#app .search input"], ["#/server", "#app h1"], ["#/tunnels", "#app h1"]]) {
      await p3.evaluate((x) => { location.hash = x; }, hash);
      await p3.waitForSelector(sel);
    }
    if (errs.length) throw new Error(errs.join(" | "));
    await p3.close();
  });

  await step("не запустилась — причина на экране, а не вечная «Загрузка…»", async () => {
    const p2 = await ctx.newPage();
    await p2.route(/\/app\.js$/, (r) => r.abort());
    await p2.goto(base, { waitUntil: "domcontentloaded" });
    await p2.waitForSelector(".boot-fail >> text=не загрузился app.js", { timeout: 5000 });
    if (!await p2.locator(".boot-fail button:has-text('Повторить')").count()) throw new Error("нет кнопки «Повторить»");
    await p2.unroute(/\/app\.js$/);
    await p2.route(/\/app\.js$/, async (r) => { const res = await r.fetch(); r.fulfill({ response: res, body: "window.x = ;" }); });
    await p2.reload({ waitUntil: "domcontentloaded" });
    await p2.waitForSelector(".boot-fail >> text=/SyntaxError|Unexpected/", { timeout: 5000 });
    await p2.close();
  });

  if (profile === "none") {
    // Сервера ещё нет: мастер создания целиком, первый клиент — сразу QR
    await step("главная без сервера", async () => {
      await page.waitForSelector("h1 >> text=Сервер не создан");
      await page.click("#tabbar a:has-text('Сервер')"); await page.waitForSelector("text=Создать сервер"); await shot("11-server-none");
    });
    await step("мастер создания", async () => {
      await page.click("button:has-text('Создать сервер')");
      await page.waitForSelector("h1 >> text=Создание сервера");
      // tools песочницы не знают ключа 3.1: причина и кнопка обновления модуля и tools
      await page.waitForSelector("text=amneziawg-tools не умеют 3.1");
      await page.waitForSelector("button:has-text('Обновить модуль и tools')");
      await page.click(".chip >> text=Мощный"); await page.waitForSelector(".chip >> text=Цепочка I1-I5");
      await page.waitForSelector("select >> nth=0");
      await shot("12-create-pro");
      await page.click(".chip >> text=AmneziaVPN");
      await page.click(".chip >> text=Пакет I1 (DNS)");
      await page.fill("input[placeholder^='случайная']", "10.66.1.7/25");
    });
    await step("мастер: неверная подсеть", async () => {
      await expectAlert("сеть /24", () => page.click("button.btn-primary:has-text('Создать сервер')"));
    });
    await step("мастер: сервер создан", async () => {
      await page.fill("input[placeholder^='случайная']", "10.66.1.7/24");
      await page.fill("input[placeholder='случайное']", "first");
      await page.click("button.btn-primary:has-text('Создать сервер')");
      await page.waitForSelector("text=Первый клиент", { timeout: 90000 });
      await shot("13-created");
      await page.click("text=Конфиг и QR");
      await page.waitForSelector("img.qr, .card.muted");
    });
    await step("обфускатор не установлен", async () => {
      await nav("/wgobf", "button:has-text('Установить')");
      await page.waitForSelector("text=STUN · видеозвонок");
      await shot("14-wgobf-install");
    });
    await step("сервер после создания", async () => {
      await nav("/server", "text=Endpoint");
      await page.waitForSelector("text=10.66.1.0/24");
    });
    const log = await page.evaluate(() => window.__log);
    say("ALERTS", JSON.stringify(log.filter((l) => l.startsWith("alert:"))));
    say("ERRORS", JSON.stringify(errors));
    await browser.close();
    return;
  }
  await step("обзор: маршруты (схема и список), живая скорость, события", async () => {
    await nav("/", ".topo svg .node[data-c=alice]");
    await page.waitForSelector(".topo svg .node[data-srv]");
    await page.waitForSelector(".rseg button.on:has-text('схема')");
    // Список: полоса долей, выходы, клиенты чипами; выбор запоминается
    await page.click(".rseg button:has-text('список')");
    await page.waitForSelector(".rlist .rx .cchip >> text=\"alice\"");
    await page.waitForSelector(".rbar i");
    if (await page.$(".topo")) throw new Error("в списке осталась схема");
    await page.reload({ waitUntil: "domcontentloaded" });
    await page.waitForSelector(".rseg button.on:has-text('список')");
    await page.click(".rseg button:has-text('схема')");
    await page.waitForSelector(".topo svg .node[data-c=alice]");
    await page.waitForSelector(".kpis .kpi >> nth=3");
    // Скорость — по двум замерам счётчиков awg0 (раз в 3 с)
    await page.waitForFunction(() => { const el = document.querySelector(".live .big .dn span"); return el && el.textContent !== "—"; },
      null, { timeout: 15000 });
    // Много клиентов: схема той же высоты, столбец клиентов листается внутри, линии — за прокруткой
    const sc = await page.evaluate(() => {
      const el = document.createElement("div"); el.className = "topo"; el.style.width = "360px";
      document.querySelector(".topo").after(el);
      const rows = Array.from({ length: 30 }, (_, i) => ({ name: "demo-" + i, online: i < 2, handshake: 1, ago: 60, today: 0 }));
      topology(el, rows, exitsModel(rows, {}), "AWG");
      const col = el.querySelector(".tcl"), first = () => (el.querySelector("g.cl path") || {}).dataset;
      const r = { rows: el.querySelectorAll(".tcl .tc").length, h: el.querySelector("svg").getAttribute("height"),
        scrolls: col.scrollHeight > col.clientHeight, before: first() && first().c };
      col.scrollTop = 400; col.dispatchEvent(new Event("scroll"));
      return new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(() => { r.after = first() && first().c; el.remove(); ok(r); })));
    });
    if (sc.rows !== 30 || !sc.scrolls || +sc.h > 400 || !sc.before || sc.before === sc.after) throw new Error("прокрутка схемы: " + JSON.stringify(sc));
    // «В сети» по живым счётчикам: 45 с без единого пакета — не в сети, сводка и схема меняются на лету
    const rule = await page.evaluate(() => {
      const now = Date.now(), c = { name: "a", online: true };
      return [liveOnline(c, { since: now - 60000, at: now, act: {} }), liveOnline(c, { since: now - 60000, at: now, act: { a: now - 5000 } }),
        liveOnline(c, { since: now - 5000, at: now, act: {} }), liveOnline(c, { since: now - 60000, at: now - 20000, act: {} }),
        liveOnline({ name: "a", online: false }, { since: now - 5000, at: now, act: { a: now } })].join();
    });
    if (rule !== "false,true,true,true,true") throw new Error("правило «в сети»: " + rule);
    const before = await page.evaluate(() => +document.querySelector(".kpis .kpi .v span").textContent);
    if (await page.locator(".topo svg .node[data-c=alice] circle").count() !== 2) throw new Error("alice не в сети на схеме");
    await page.evaluate(() => { S.live.act = {}; S.live.since = Date.now() - 60000; });
    await page.waitForFunction((n) => +document.querySelector(".kpis .kpi .v span").textContent === n - 1, before, { timeout: 10000 });
    await page.waitForFunction(() => document.querySelectorAll(".topo svg .node[data-c=alice] circle").length === 1, null, { timeout: 5000 });
    await page.waitForSelector(".head .sub >> text=/^" + (before - 1) + " из /");
    await page.click(".topo svg .node[data-c=alice]");
    await page.waitForURL(/#\/client\/alice$/);
  });
  await step("список", async () => { await nav("/clients", "[data-name]"); await page.waitForSelector(".head h1 >> text=Клиенты"); await shot("02-clients"); });
  await step("поиск", async () => {
    await page.fill("input[type=search]", "анн");
    const n = await page.locator("[data-name]").count();
    if (n !== 1) throw new Error("ожидался 1 клиент по заметке, найдено " + n);
    await page.fill("input[type=search]", "");
    // Список перерисовывается на каждую букву — поле поиска не должно терять фокус (на телефоне закрылась бы клавиатура)
    await page.click("input[type=search]");
    await page.keyboard.type("al");
    const focused = await page.evaluate(() => document.activeElement && document.activeElement.type === "search");
    const val = await page.inputValue("input[type=search]");
    if (!focused || val !== "al") throw new Error(`фокус потерян при вводе: focused=${focused} value=${val}`);
    await page.fill("input[type=search]", "");
  });
  await step("вид списком", async () => {
    await page.click(".seg button >> nth=1");
    await page.waitForSelector(".card.list [data-name=alice]");
    await page.click(".seg button >> nth=0");
    await page.waitForSelector(".ecard[data-name=alice]");
  });
  await step("карточка", async () => { await page.click("[data-name=alice] .name"); await page.waitForSelector("text=Мониторинг активности"); await shot("03-card"); });
  await step("мониторинг", async () => {
    await page.click("text=Мониторинг активности");
    await page.waitForSelector(".switch.on");
  });
  await step("трафик клиента: график по дням", async () => {
    await nav("/client/alice", ".chart.line path.ln");
    if (await page.locator(".chart.line .hit").count() !== 30) throw new Error("ждали 30 дней на линии");
    await page.locator(".chart.line .hit").nth(-3).click();
    await page.waitForSelector(".chart.line.sel");
    const cap = await page.textContent(".chart .cap");
    if (!/МБ|ГБ/.test(cap)) throw new Error("подпись дня без объёма: " + cap);
    await shot("03a-traffic");
  });
  await step("лимит трафика: готовый размер", async () => {
    await page.click(".actions button:has-text('Лимит')"); await page.waitForSelector(".sheet");
    await page.click(".sheet >> text=50 ГБ в месяц");
    await page.waitForSelector(".kv >> text=/из 50.0 ГБ за месяц/");
    await page.waitForSelector(".meter");
    await page.waitForSelector(".tag >> text=/лимит \\d+%/");
  });
  await step("лимит трафика: «50GB» — как parse_size в awg2", async () => {
    await nav("/client/alice/limit", "#app:not(.reloading) input");
    await page.fill("#app input", "50GB");
    await page.click("button:has-text('Сохранить')");
    await page.waitForSelector(".kv >> text=/из 50.0 ГБ за месяц/");
  });
  await step("лимит трафика: свой размер «всего»", async () => {
    // Экран был открыт шагом выше — сначала снимок; поле — из свежего
    await nav("/client/alice/limit", "#app:not(.reloading) input");
    await page.fill("#app input", "1.5T");
    await page.click(".seg button:has-text('Всего')");
    await page.click("button:has-text('Сохранить')");
    await page.waitForSelector(".kv >> text=/из 1.5 ТБ всего/");
    await shot("03b-limit");
    await page.click(".actions button:has-text('Лимит')"); await page.waitForSelector(".sheet");
    await page.click(".sheet >> text=Снять лимит");
    await page.waitForSelector(".kv >> text=нет");
  });
  await step("QR", async () => { await page.click("text=Конфиг и QR"); await page.waitForSelector("img.qr"); await shot("04-qr"); });
  await step("в чат (одна кнопка, без ZIP — он только в веб-панели)", async () => {
    if (await page.$(".confbtns") || await page.$("button:has-text('ZIP')")) throw new Error("в Mini App кнопка ZIP");
    await page.click("text=Отправить файл в чат"); await page.waitForSelector(".toast >> text=Файл и QR");
  });
  await step("срок", async () => {
    await nav("/client/alice", "text=Срок");
    await page.click(".actions button:has-text('Срок')"); await page.waitForSelector(".sheet"); await shot("05-expire-sheet");
    await page.click(".sheet >> text=7 дней"); await page.waitForSelector(".sgrid >> text=/^6д/");
  });
  await step("смена экрана закрывает лист и «Тему»: выбор в них уже ни к чему", async () => {
    await nav("/clients", "[data-name=alice]");
    await page.click("[data-name=alice] .name");
    await page.waitForURL(/#\/client\/alice$/);
    await page.click(".actions button:has-text('Срок')"); await page.waitForSelector(".sheet");
    await page.evaluate(() => window.__back());                     // кнопка «Назад» Telegram
    await page.waitForURL(/#\/clients$/);
    await page.waitForFunction(() => !document.querySelector(".sheet-bg"), null, { timeout: 3000 })
      .catch(() => { throw new Error("лист срока остался поверх списка"); });
    await page.click(".top button[aria-label='Тема']");
    await page.waitForSelector(".drawer.on >> text=Тема");
    await page.evaluate(() => { location.hash = "/server"; });
    await page.waitForSelector("text=Endpoint");
    if (await page.locator(".drawer.on").count()) throw new Error("«Тема» осталась поверх нового экрана");
  });
  await step("новый клиент", async () => {
    await nav("/add", "input");
    await page.fill("input", "carol");
    await page.selectOption("select", "+1d");
    await shot("06-add");
    await page.click("text=Создать");
    await page.waitForURL(/#\/client\/carol\/qr/); await page.waitForSelector("img.qr, .card.muted");
  });
  await step("переименование: «Назад» не ведёт на карточку со старым именем", async () => {
    await nav("/clients", "[data-name=carol]");
    await page.click("[data-name=carol] .name");
    await page.waitForURL(/#\/client\/carol$/);
    await page.click(".actions button:has-text('Имя')");
    await page.waitForURL(/#\/client\/carol\/rename$/);
    await page.waitForSelector("#app input");
    await page.fill("#app input", "dave");
    await page.click("button:has-text('Сохранить')");
    await page.waitForURL(/#\/client\/dave$/);
    await page.waitForSelector("text=Мониторинг активности");
    await page.evaluate(() => window.__back());
    await page.waitForURL(/#\/clients$/, { timeout: 5000 }).catch(() => { throw new Error("«Назад» после переименования: " + page.url()); });
    await nav("/client/dave/rename", "#app input");
    await page.fill("#app input", "carol");
    await page.click("button:has-text('Сохранить')");
    await page.waitForURL(/#\/client\/carol$/);
  });
  await step("мимикрия клиента: с вопросом и один запрос на двойной тап", async () => {
    await nav("/client/carol/mimicry", ".item");
    let n = 0;
    const count = (r) => { if (/"client","mimicry"/.test(r.postData() || "")) n++; };
    page.on("request", count);
    await page.evaluate(() => { const it = [...document.querySelectorAll(".item")].find((x) => /Без I1-I5/.test(x.textContent)); it.click(); it.click(); });
    await page.waitForURL(/#\/client\/carol\/qr$/);
    await page.waitForTimeout(500);
    page.off("request", count);
    const asked = (await page.evaluate(() => window.__log)).filter((l) => l.startsWith("confirm:Сменить мимикрию carol"));
    if (n !== 1 || asked.length !== 1) throw new Error(`запросов ${n}, вопросов ${asked.length}`);
  });
  await step("массовое создание: количество — только целое", async () => {
    await nav("/bulk", "input");
    await page.fill("input >> nth=0", "t");
    await page.fill("input[type=number]", "2.5");
    await expectAlert("Количество", () => page.click("button.btn-primary:has-text('Создать')"));
  });
  await step("массовое создание", async () => {
    await nav("/bulk", "input");
    await page.fill("input >> nth=0", "t");
    await page.fill("input[type=number]", "2");
    await page.click("text=Создать");
    await page.waitForSelector("text=Создано: 2", { timeout: 60000 });
    await shot("07-bulk-done");
  });
  await step("выбрать и удалить", async () => {
    await nav("/clients", "[data-name]");
    await page.click(".ctools button:has-text('Выбрать')");
    await page.click("[data-name=t-001] .name"); await page.click("[data-name=t-002] .name");
    await shot("08-select");
    await page.click(".bar >> text=Удалить");
    await page.waitForSelector(".toast >> text=Удалено: 2");
    // Список обновляется на месте: удалённые строки уходят, как только придёт новый
    await page.waitForSelector("[data-name=t-001]", { state: "detached", timeout: 10000 }).catch(() => { throw new Error("t-001 остался"); });
    await page.waitForSelector("[data-name]");
  });
  await step("мимикрия", async () => {
    await nav("/client/alice/mimicry", ".item");
    await page.waitForSelector(".item:has-text('Как у сервера') .sub");
    await shot("09-mimicry");
  });
  await step("удалить клиента: возврат к списку, первое «Назад» уводит с него", async () => {
    await nav("/clients", "[data-name=carol]");
    await page.click("[data-name=carol] .name");
    await page.waitForURL(/#\/client\/carol$/);
    await page.click("text=Удалить клиента");
    await page.waitForURL(/#\/clients$/);
    await page.waitForSelector("[data-name=carol]", { state: "detached" });
    await page.evaluate(() => window.__back());
    await page.waitForFunction(() => location.hash !== "#/clients", null, { timeout: 5000 })
      .catch(() => { throw new Error("после удаления в истории — второй список подряд"); });
  });

  // ── Сервер ──
  await step("сервер", async () => {
    await nav("/server", "text=Endpoint"); await page.waitForSelector("text=Модуль ядра"); await shot("20-server");
    // Сервер на 2.0 — обычный выбор: подсказка о 3.1 не висит предупреждением (переход — в «Протоколе»)
    for (const t of await page.locator("#app .card.warn").allTextContents()) if (/3\.1/.test(t)) throw new Error("плашка про 3.1: " + t);
  });
  await step("рестарт awg0 — с вопросом, как в палитре", async () => {
    await page.click(".ecard button:has-text('Рестарт')"); await page.waitForSelector(".toast");
    if (!(await page.evaluate(() => window.__log)).some((l) => l.startsWith("confirm:Перезапустить awg0"))) throw new Error("без подтверждения");
  });
  await step("протокол", async () => { await nav("/server/proto", "text=Перейти на 3.1"); await shot("21-proto"); });
  await step("параметры AWG", async () => {
    await nav("/server/params", "input[data-key=Jc]");
    await shot("21b-params");
    await page.fill("input[data-key=Jc]", "7");
    await page.waitForSelector("input[data-key=Jc].chg");
    await page.waitForSelector(".bar button.btn-primary:not([disabled])");
    // S1 у сервера случайный (профиль none создаёт свой) — совпадение длин считаем от него
    const s1 = Number(await page.inputValue("input[data-key=S1]"));
    const s2 = await page.inputValue("input[data-key=S2]");
    await page.fill("input[data-key=S2]", String(s1 + 56));
    await page.waitForSelector(".card.bad >> text=S1 и S2");
    await page.waitForSelector(".bar button.btn-primary[disabled]");
    if (/\bnull\b/.test(await page.textContent("#app"))) throw new Error("в форме «null»");
    await shot("21c-params-error");
    await page.fill("input[data-key=S2]", s2);
    const s4 = await page.inputValue("input[data-key=S4]");
    await page.fill("input[data-key=S4]", s4 === "20" ? "21" : "20");
    await page.waitForSelector("input[data-key=S4].chg");
    await page.waitForSelector(".bar button.btn-primary:not([disabled])");
    await page.click(".bar button.btn-primary");
    await page.waitForSelector(".sheet >> text=Клиентам нужны новые конфиги");
    await page.click(".sheet button:has-text('Все конфиги архивом')");
    await page.waitForSelector(".toast >> text=Архив всех конфигов");
    await page.waitForFunction(() => {
      const jc = document.querySelector("input[data-key=Jc]");
      return jc && jc.value === "7" && !document.querySelector("input.chg");
    });
    // Перед записью — авто-бэкап; убираем его, чтобы раздел «Бэкапы» начинался с пустого списка
    const dir = `${sandboxRoot}/awg_backup`;
    const auto = fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.startsWith("auto_params_")) : [];
    if (!auto.length) throw new Error("нет авто-бэкапа перед записью параметров");
    auto.forEach((f) => fs.unlinkSync(`${dir}/${f}`));
    if (!fs.readdirSync(dir).length) fs.rmdirSync(dir);
  });
  await step("endpoint", async () => {
    await nav("/server/endpoint", "input");
    await expectAlert("vpn.example.com", async () => { await page.fill("input", "bad"); await page.click("text=Сохранить домен"); });
    await page.fill("input", "vpn.example.com");
    await page.click("text=Переписать в выданных конфигах");
    await shot("22-endpoint");
    await page.click("text=Сохранить домен");
    await page.waitForSelector(".toast >> text=vpn.example.com");
    await nav("/server", "text=Endpoint");
    await page.waitForSelector("text=vpn.example.com");
  });
  await step("модуль ядра", async () => {
    await nav("/server/module", "text=Ядро");
    await page.click("summary"); await page.waitForSelector("details[open] pre");
    await shot("23-module");
  });
  await step("журнал", async () => { await nav("/log/manager", "pre"); });
  await step("антисканер: выключен, три списка, исключения, «Включить»", async () => {
    await nav("/server/antiscan", "text=Сети госорганов");
    const n = await page.locator(".card.list .item .check").count();
    if (n !== 3) throw new Error("ждали 3 списка, есть " + n);
    await page.waitForSelector("text=○ выключен");
    await page.waitForSelector("button:has-text('Включить')");
    await page.waitForSelector("input[aria-label='Адрес или подсеть']");
    await shot("23b-antiscan");
  });
  await step("антисканер: включение — с вопросом и предупреждением", async () => {
    await page.route(/\/api\/call$/, (route) => {
      const b = JSON.parse(route.request().postData() || "{}");
      if (b.args && b.args[0] === "antiscan" && b.args[1] === "on")
        return route.fulfill({ contentType: "application/json", body: JSON.stringify({ ok: true, log: "", error: "", data: null }) });
      return route.continue();
    });
    try {
      await page.click("button:has-text('Включить')");
      await page.waitForSelector(".toast >> text=Антисканер включён");
      const asked = (await page.evaluate(() => window.__log)).filter((l) => l.startsWith("confirm:Включить антисканер"));
      if (!asked.length || !/клиенты VPN/.test(asked[0])) throw new Error("включение без подтверждения: " + JSON.stringify(asked));
    } finally { await page.unroute(/\/api\/call$/); }
  });
  await step("антисканер: длинный IPv6 в исключениях виден целиком (перенос, без обрезки)", async () => {
    const six = "2001:db8:1234:5678:9abc:def0:1234:5678/128";
    await page.route(/\/api\/call$/, (route) => {
      const b = JSON.parse(route.request().postData() || "{}");
      if (b.args && b.args[0] === "antiscan" && b.args[1] === "status")
        return route.fulfill({ contentType: "application/json", body: JSON.stringify({ ok: true, log: "", error: "", data: {
          enabled: true, active: true, v4: 1, v6: 1, dropped: 1, updated: 1790000000, error: "", lists: [], allow: [six], top: [] } }) });
      return route.continue();
    });
    try {
      await nav("/server/antiscan", "text=" + six.slice(0, 12));
      const r = await page.evaluate((six) => {
        const e = [...document.querySelectorAll(".item .title.mono")].find((x) => x.textContent === six);
        return e ? [e.scrollWidth - e.clientWidth, document.documentElement.scrollWidth - document.documentElement.clientWidth] : null;
      }, six);
      if (!r || r[0] > 0 || r[1] > 0) throw new Error("адрес обрезан или страница шире экрана: " + JSON.stringify(r));
    } finally { await page.unroute(/\/api\/call$/); }
  });

  // ── Туннели и DNS ──
  await step("туннели", async () => {
    await nav("/tunnels", ".ecard");
    const n = await page.locator(".ecard").count();
    if (n !== 6) throw new Error("ждали 6 карточек (4 туннеля, каскад, DNS), есть " + n);
    await page.waitForSelector(".sgrid >> text=Exit-ноды");
    await shot("30-tunnels");
  });
  await step("WARP", async () => { await page.click("[data-name=WARP] .name"); await page.waitForSelector("text=Бэкенд"); await shot("31-warp"); });
  await step("клиенты в WARP", async () => {
    await nav("/tunnels/warp/clients", ".item");
    await page.click(".item >> text=alice");
    await page.waitForSelector(".item:has-text('alice') >> text=напрямую");
    await shot("32-warp-clients");
  });
  await step("клиенты в WARP: двойной тап — один запрос, на экране — отправленное", async () => {
    await nav("/tunnels/warp/clients", ".item");
    const sel = ".item:has-text('alice')", was = await page.textContent(sel + " .sub");
    let n = 0;
    const count = (r) => { if (/"tunnels","client"/.test(r.postData() || "")) n++; };
    page.on("request", count);
    await page.evaluate(() => { const it = [...document.querySelectorAll(".item")].find((x) => /alice/.test(x.textContent)); it.click(); it.click(); });
    await page.waitForTimeout(400);
    await page.waitForFunction(() => !document.querySelector(".item.reloading"));
    page.off("request", count);
    const now = await page.textContent(sel + " .sub");
    if (n !== 1 || /напрямую/.test(was) === /напрямую/.test(now)) throw new Error(`запросов ${n}: «${was}» → «${now}»`);
    await nav("/tunnels/warp/clients", ".item");
    if (await page.textContent(sel + " .sub") !== now) throw new Error("на сервере другое: " + await page.textContent(sel + " .sub"));
  });
  await step("Xray", async () => { await nav("/tunnels/xray", "text=Установить"); await shot("33-xray"); });
  await step("tun2socks", async () => {
    await nav("/tunnels/tun2socks", "input");
    await expectAlert("IP:ПОРТ", async () => { await page.fill("input", "нет"); await page.click("text=Включить"); });
    await shot("34-t2s");
  });
  await step("exit-ноды: тумблер туннеля, все / выбранные", async () => {
    await nav("/tunnels/exits", "text=Кого вести через ноды");
    await page.waitForSelector(".item >> text=n1");
    await page.waitForSelector("[data-tunnel=on] .switch.on");
    await page.waitForSelector("[data-tunnel=on] >> text=включён · все клиенты");
    await shot("35-exits");
    await page.click(".exmode button:has-text('Выбранные')");
    await page.waitForSelector(".exl .item[data-name=alice]");
  });
  await step("exit-ноды: никого / клиент по одному / поиск / все", async () => {
    const n = await page.locator(".exl .item").count();
    await page.click(".ctools button:has-text('Никого')");
    await page.waitForFunction(() => !document.querySelector(".exl .switch.on"));
    await page.waitForSelector(`text=через ноды: 0 из ${n}`);
    await page.click(".exl .item[data-name=alice] .switch");
    await page.waitForSelector(".exl .item[data-name=alice] .switch.on");
    await page.waitForSelector(".exl .item[data-name=alice] >> text=общий выход");
    await page.waitForSelector(`text=через ноды: 1 из ${n}`);
    await page.fill(".ctools input[type=search]", "ali");
    await page.waitForFunction(() => document.querySelectorAll(".exl .item").length === 1);
    await page.fill(".ctools input[type=search]", "");
    await page.click(".ctools button:has-text('Все')");
    await page.waitForSelector(`text=через ноды: ${n} из ${n}`);
    await shot("36-exit-pick");
  });
  await step("exit-ноды: тумблер туннеля выключает их, старый адрес ведёт сюда же", async () => {
    // В песочнице systemctl — заглушка: служба «работает» и после остановки,
    // поэтому проверяем ответ awg2 на exits down, а не состояние после
    await page.click("[data-tunnel=on]");
    await page.waitForSelector(".toast >> text=Exit-ноды выключены");
    await nav("/tunnels/exits/clients", "text=Кого вести через ноды");
    await page.waitForURL(/#\/tunnels\/exits$/);
  });
  await step("карточка клиента: маршрут выбирается на месте", async () => {
    await nav("/client/alice", ".rcard .rchips button[data-v=shared].on");
    await page.click(".rcard .rchips button[data-v=n1]");
    await page.waitForSelector(".rcard .rchips button[data-v=n1].on");
    await page.click(".rcard .rchips button[data-v=off]");
    await page.waitForSelector(".rcard .rchips button[data-v=off].on");
    await page.click(".rcard .rchips button[data-v=shared]");
    await page.waitForSelector(".rcard .rchips button[data-v=shared].on");
    await nav("/tunnels/exits", ".exmode");
    await page.click(".exmode button:has-text('Все клиенты')");
    await page.waitForSelector("[data-tunnel=on] >> text=включён · все клиенты");
  });
  await step("каскад: добавить", async () => {
    await nav("/tunnels/cascade/add", "input");
    await page.fill("input[placeholder='51820']", "5555");
    await page.fill("input[placeholder='5.6.7.8']", "5.6.7.8");
    await page.fill("input[placeholder^='например']", "de-server");
    await shot("37-cascade-add");
    await page.click("button:has-text('Добавить')");
    await page.waitForSelector(".toast >> text=UDP 5555 → 5.6.7.8:5555");
    await nav("/tunnels/cascade", ".item");
    await page.waitForSelector("text=UDP 5555 → 5.6.7.8:5555");
    await shot("38-cascade");
  });
  await step("каскад: удалить", async () => {
    await page.click(".item >> text=UDP 5555");
    await page.waitForSelector("text=Правил нет");
  });
  await step("DNS", async () => { await nav("/tunnels/dns", "text=Включить"); await shot("39-dns"); });
  await step("всё напрямую", async () => {
    await nav("/tunnels", ".ecard");
    await page.click("text=Всё напрямую");
    await page.waitForSelector(".toast >> text=клиенты идут напрямую");
  });

  await step("тема вручную", async () => {
    const before = await page.evaluate(() => document.documentElement.dataset.theme);
    await page.click(".top button[aria-label='Тема']");
    await page.waitForSelector(".drawer.on >> text=Тема");
    await page.click(`.drawer.on .chip:has-text('${before === "dark" ? "Светлая" : "Тёмная"}')`);
    await page.reload({ waitUntil: "domcontentloaded" }); await page.waitForSelector("h1");
    const after = await page.evaluate(() => document.documentElement.dataset.theme);
    if (after === before) throw new Error("тема не сменилась или не запомнилась");
    await page.click(".top button[aria-label='Тема']");
    await page.click(".drawer.on .chip:has-text('Как Telegram')");
    if (await page.evaluate(() => document.documentElement.dataset.theme) !== theme) throw new Error("«Как Telegram» не вернуло тему Telegram");
    await page.click(".drawer.on button:has-text('Готово')");
  });

  await step("тема: акцент, скругление, масштаб, клетка", async () => {
    const grid = () => page.evaluate(() => document.body.classList.contains("grid-bg"));
    if (await grid()) throw new Error("клетка на фоне включена по умолчанию");
    await page.click(".top button[aria-label='Тема']");
    await page.click(".drawer.on .tg[aria-label='Клетка на фоне']");
    await page.waitForSelector(".drawer.on .tg[aria-checked=true] .switch.on");
    if (!await grid()) throw new Error("клетка не включилась");
    await page.click(".drawer.on .swt[aria-label='Океан']");
    await page.$eval(".drawer.on input[aria-label='Масштаб']", (r) => { r.value = "90"; r.dispatchEvent(new Event("input")); });
    await page.$eval(".drawer.on input[aria-label='Скругление углов']", (r) => { r.value = "4"; r.dispatchEvent(new Event("input")); });
    await page.waitForSelector(".drawer.on .swt.on[aria-label='Океан']");
    await shot("25-look");
    const look = () => page.evaluate(() => { const st = document.documentElement.style;
      return [st.getPropertyValue("--acc").trim(), st.zoom, st.getPropertyValue("--rb").trim()]; });
    const a = await look();
    if (!/^hsl\(198/.test(a[0]) || a[1] !== "0.9" || a[2] !== "4px") throw new Error("акцент/масштаб/скругление не применились: " + a);
    // Знак Тулзы — в цвет акцента, как слово «toolza»: перекрашен в шапке и во вкладке
    const tz = () => page.evaluate(() => [document.querySelector(".top img.tz").src, document.getElementById("favicon").href]);
    const [logo, fav] = await tz();
    const dec = decodeURIComponent(logo.slice(logo.indexOf(",") + 1));
    if (!logo.startsWith("data:image/svg+xml;charset=utf-8,") || fav !== logo || /#2fe3ad|#27e57f/i.test(dec) || !/<svg/.test(dec))
      throw new Error("знак не перекрашен под акцент: " + logo.slice(0, 80));
    await page.reload({ waitUntil: "domcontentloaded" }); await page.waitForSelector("h1");
    const kept = await look();
    if (kept.join() !== a.join()) throw new Error("не запомнилось: " + kept);
    if (!await grid()) throw new Error("клетка не запомнилась");
    await page.click(".top button[aria-label='Тема']");
    await page.click(".drawer.on button:has-text('Сбросить')");
    await page.click(".drawer.on button:has-text('Готово')");
    const reset = await look();
    if (reset[0] !== "" || reset[1] !== "" || reset[2] !== "16px" || await grid()) throw new Error("сброс не сработал: " + reset);
    const [logo0, fav0] = await tz();
    if (logo0 !== await page.evaluate(() => TZ_ICON) || fav0 !== logo0) throw new Error("после сброса знак не исходный");
  });

  await step("«Ещё»: остальные разделы снизу", async () => {
    await nav("/", ".head h1");
    await page.click("#tabbar a:has-text('Ещё')");
    await page.waitForSelector("#more.on .mg a >> nth=7");
    await shot("26-more");
    await page.click("#more .mg a:has-text('Бэкапы')");
    await page.waitForURL(/#\/backup$/);
    await page.waitForSelector("#tabbar a.on:has-text('Ещё')");      // раздел из «Ещё» — подсвечено «Ещё»
  });

  await step("нажатие на открытую вкладку обновляет экран", async () => {
    await nav("/clients", "[data-name]");
    await page.evaluate(() => { document.querySelector("#app h1").dataset.keep = "1"; });
    await page.click("#tabbar a:has-text('Клиенты')");
    await page.waitForFunction(() => document.querySelector("#app h1") && !document.querySelector("#app h1[data-keep]"), null, { timeout: 5000 })
      .catch(() => { throw new Error("экран не обновился"); });
  });
  await step("ошибка: строки журнала, повторяющие её текст, не дублируются", async () => {
    const before = (await alerts()).length;
    await page.evaluate(() => { const e = new Error("Нет места на диске"); e.log = "→ Проверяю диск\n  × Нет места на диске"; fail(e); });
    const got = (await alerts()).slice(before).join("\n");
    await page.evaluate(() => { window.__log = window.__log.filter((l) => !l.startsWith("alert:")); });
    if (!/Проверяю диск/.test(got) || /×/.test(got) || got.split("Нет места на диске").length !== 2) throw new Error(JSON.stringify(got));
  });
  await step("длинный вопрос в окне Telegram режется с середины — вопрос в конце остаётся", async () => {
    const r = await page.evaluate(() => {
      const t = "Меняются: S1, S2.\nS1, S2 обязаны совпадать у клиентов: все клиенты потеряют связь.\n" + "▲ предупреждение. ".repeat(20)
        + "\nПеред записью — авто-бэкап. Применить?";
      const p = popupText(t);
      return [p.length, p.startsWith("Меняются"), p.endsWith("Применить?")];
    });
    if (r[0] > 256 || !r[1] || !r[2]) throw new Error(JSON.stringify(r));
  });
  await step("обрыв связи — «Нет связи с сервером», а не «Failed to fetch»", async () => {
    await nav("/client/alice/note", "textarea");
    await page.route(/\/api\/client\/note$/, (r) => r.abort());
    try { await expectAlert("Нет связи с сервером", () => page.click("button:has-text('Сохранить')")); }
    finally { await page.unroute(/\/api\/client\/note$/); }
  });
  await step("обзор: клиенты не загрузились — так и сказано, с повтором", async () => {
    await page.route(/\/api\/clients$/, (r) => r.abort());
    try {
      await nav("/", ".head h1");
      await page.waitForSelector("[data-name=clients-error] button:has-text('Повторить')");
      if (await page.locator("text=Клиентов пока нет").count() || await page.locator("text=/^Лимитов нет/").count())
        throw new Error("без списка клиентов — «Клиентов пока нет» / «Лимитов нет»");
    } finally { await page.unroute(/\/api\/clients$/); }
    await page.click("[data-name=clients-error] button:has-text('Повторить')");
    await page.waitForSelector(".topo svg .node[data-c=alice], .rlist");
  });
  await step("палитра команд", async () => {
    await page.click(".top .kbar");
    await page.waitForSelector(".pal.on input");
    await page.keyboard.type("сервер");
    await page.waitForSelector(".pal li.on:has-text('Сервер')");
    await page.keyboard.press("Enter");
    await page.waitForURL(/#\/server$/);
  });

  // ── Диагностика ──
  await step("обзор: трафик за 14 дней — по клиентам и линией", async () => {
    await nav("/", "[data-name=traffic] .chart");
    await page.waitForSelector("[data-name=traffic] .chips button.on >> text=Все");
    if (await page.locator("[data-name=traffic] .chart .bar").count() !== 2) throw new Error("«Все»: ждали столбцы двух клиентов");
    const cap = await page.textContent("[data-name=traffic] .chart .cap");
    if (!cap.startsWith("alice")) throw new Error("первым — клиент с наибольшим трафиком: " + cap);
    await shot("01b-traffic-clients");
    await page.click("[data-name=traffic] .chips button >> text=bob");
    await page.waitForSelector("[data-name=traffic] .chart.line path.ln");
    await nav("/", "[data-name=traffic] .chart.line");
    if (!(await page.textContent("[data-name=traffic] .chips button.on")).includes("bob")) throw new Error("выбор клиента не запомнился");
    await shot("01c-traffic-client");
    await page.click("[data-name=traffic] .chips button >> text=Все");
    await page.waitForSelector("[data-name=traffic] .chart .bar");
  });
  await step("диагностика", async () => { await nav("/diag", "text=Система"); await shot("40-diag"); });
  await step("домены мимикрии", async () => {
    await page.click("text=Домены мимикрии: мир");
    await page.waitForSelector("button:has-text('Назад')", { timeout: 90000 });
    await shot("41-domains");
  });
  await step("задача: связь пропала — «нет связи», «Повторить проверку» доводит до итога", async () => {
    await nav("/diag", "text=Система");
    await page.evaluate(() => { window.AWG_JOB_LOST_MS = 2500; });
    await page.route(/\/api\/job\/status$/, (r) => r.abort());
    try {
      await page.click("text=Домены мимикрии: мир");
      await page.waitForSelector("h1 .pill:has-text('нет связи')", { timeout: 20000 });
      await page.waitForSelector("text=задача могла продолжиться на сервере");
      await page.waitForSelector("button:has-text('Назад')");
    } finally { await page.unroute(/\/api\/job\/status$/); await page.evaluate(() => { delete window.AWG_JOB_LOST_MS; }); }
    await page.click("button:has-text('Повторить проверку')");
    await page.waitForFunction(() => /готово|ошибка/.test((document.querySelector("#app h1 .pill") || {}).textContent || ""),
      null, { timeout: 90000 });
  });
  await step("задача: ушли с экрана — итог подсказкой", async () => {
    await nav("/diag", "text=Система");
    // Первый ответ о задаче — уже после ухода с экрана
    await page.route(/\/api\/job\/status$/, async (r) => { await new Promise((ok) => setTimeout(ok, 2500)); r.continue().catch(() => {}); });
    try {
      await page.click("text=Домены мимикрии: мир");
      await page.waitForSelector("h1 .pill:has-text('идёт')");
      await page.evaluate(() => { location.hash = "/server"; });
      await page.waitForSelector("text=Endpoint");
      await page.waitForSelector(".toast >> text=/Домены мимикрии \\(мир\\): (готово|ошибка)/", { timeout: 90000 });
    } finally { await page.unroute(/\/api\/job\/status$/); }
  });
  await step("журналы", async () => {
    await nav("/diag/logs", ".item");
    const n = await page.locator(".item").count();
    if (n < 15) throw new Error("журналов в списке " + n);
    await page.click(".item >> text=Telegram-бот"); await page.waitForSelector("pre");
  });
  await step("тест мимикрии: клиенты", async () => { await nav("/diag/sniff", ".item"); await page.waitForSelector(".item >> text=alice"); });
  await step("DPI у клиента", async () => {
    await nav("/diag/dpi", "pre");
    await page.click("pre >> nth=0"); await page.waitForSelector(".toast >> text=Скопировано");
    await shot("42-dpi");
  });

  // ── Бэкапы ──
  await step("бэкап: создать и в чат", async () => {
    await nav("/backup", "text=Бэкапов на сервере нет");
    await page.click("button:has-text('Создать')");
    await page.waitForSelector("text=Файл — в чате с ботом", { timeout: 90000 });
    await shot("43-backup-done");
  });
  await step("автобэкап", async () => {
    await nav("/backup", "[data-name=autobackup]");
    await page.click("[data-name=autobackup] button:has-text('Каждый день')");
    await page.waitForSelector("[data-name=autobackup] >> text=/ежедневно · хранить 7/");
    await page.click("[data-name=autobackup] button:has-text('14')");
    await page.waitForSelector("[data-name=autobackup] >> text=/хранить 14/");
    await shot("44a-autobackup");
    await page.click("[data-name=autobackup] button:has-text('Выкл')");
    await page.waitForSelector("[data-name=autobackup] >> text=выключен");
  });
  await step("бэкапы на сервере", async () => {
    await nav("/backup", ".item");
    if (await page.locator(".item").count() !== 2) throw new Error("ждали каталог и архив");
    await shot("44-backups");
    await page.click(".item >> nth=0");
    await page.click(".sheet >> text=Прислать в чат");
    await page.waitForSelector(".toast >> text=в чате с ботом");
  });
  await step("бэкап с телефона", async () => {
    const dir = `${sandboxRoot}/awg_backup`;
    const archive = fs.readdirSync(dir).find((f) => f.endsWith(".tar.gz"));
    await page.setInputFiles("input[type=file]", `${dir}/${archive}`);
    await page.waitForURL(/#\/backup\/restore$/);
    await page.waitForSelector("text=Клиентов");
    await shot("45-restore");
  });
  await step("восстановление", async () => {
    await page.click("button:has-text('Восстановить')");
    await page.waitForSelector("h1:has-text('Восстановление из бэкапа') .pill.ok", { timeout: 90000 });
    await shot("46-restored");
  });
  await step("не бэкап — понятная ошибка", async () => {
    await nav("/backup", ".item");
    await page.setInputFiles("input[type=file]", { name: "photo.tar.gz", mimeType: "application/gzip", buffer: Buffer.from("not a tar") });
    await page.waitForSelector("text=Архив не распаковался");
    await page.waitForSelector("text=это не архив tar.gz");
  });

  // ── Обновление ──
  // Главная сама заглядывает в канал — v9.9.9 может быть уже известна
  await step("обновление", async () => { await nav("/update", "text=Канал"); await page.waitForSelector("text=стабильный"); await shot("47-update"); });
  await step("проверка обновлений — на месте, экран не перерисовывается", async () => {
    await page.evaluate(() => { document.querySelector("#app h1").dataset.keep = "1"; });
    await page.click("button:has-text('Проверить')");
    await page.waitForSelector(".toast >> text=Доступна v9.9.9");
    await page.waitForSelector("button:has-text('Обновить до v9.9.9')");
    if (!await page.$("#app h1[data-keep]")) throw new Error("экран обновления перерисовался целиком");
    // Список изменений из CHANGELOG.md канала — разметка без innerHTML
    await page.waitForSelector(".chlog-h >> text=Что нового в v9.9.9");
    await page.waitForSelector(".chlog b >> text=Новое");
    await page.waitForSelector(".chlog code >> text=сборка");
    await page.waitForSelector(".chlog li >> text=со второй строкой");
    if (await page.locator(".chlog-v >> text=v1.1.1").count()) throw new Error("в списке изменений — уже установленная версия");
    await shot("48-update-available");
  });
  await step("стрелка ↑ у версии в шапке", async () => {
    await page.waitForSelector(".top .lockup text >> text=↑");
    if (!/доступна v9\.9\.9/.test(await page.getAttribute(".top .lock", "title"))) throw new Error("у стрелки нет подсказки с версией");
    await page.waitForSelector("#tabbar .tdot");                       // точка на «Ещё»: обновление — там
    await nav("/", ".top .lockup");
    await shot("48b-update-arrow");
    await page.click(".top .lock");
    await page.waitForURL(/#\/update$/);
    await page.waitForSelector("text=Канал");
  });
  await step("бета-канал", async () => {
    // Сводка, запрошенная до переключения, приходит после него — прежний канал
    // не затирает выбранный (иначе шапка — «стабильный» до следующей сводки)
    let late = null;
    await page.route("**/api/status", async (r) => {
      const first = !late;
      if (first) late = new Promise((ok) => setTimeout(ok, 2500));
      const resp = await r.fetch();          // ответ сервера — на момент запроса
      if (first) await late;
      return r.fulfill({ response: resp });
    });
    await page.evaluate(() => { refreshStatus(); });
    await page.click("button:has-text('Бета-канал')");
    await page.waitForSelector("text=бета — ранние сборки");
    await page.waitForFunction(() => /beta/.test(document.querySelector(".top .lockup").getAttribute("aria-label")));
    await late;
    await page.waitForTimeout(300);
    await page.unroute("**/api/status");
    if (!/beta/.test(await page.getAttribute(".top .lockup", "aria-label"))) throw new Error("запоздалая сводка вернула шапке стабильный канал");
    await page.waitForSelector(".top .lockup text >> text=BETA");
    await shot("48c-beta");
    if (/null|undefined/.test(await page.textContent(".top"))) throw new Error("в шапке «null»");
    // Самая длинная надпись — версия, ↑ и BETA: флаг её не перекрывает, шапка не шире экрана
    const vp = page.viewportSize();
    for (const width of [320, 360, 375, 390, 412]) {
      await page.setViewportSize({ width, height: vp.height });
      const r = await page.evaluate(() => {
        drawTop();
        const box = (sel) => document.querySelector(sel).getBoundingClientRect();
        const l = box(".top .lockup"), f = box(".top .cflag"), k = box(".top .kbar");
        // Правый край шапки (кнопка «Тема») — не за экраном; и экран «Обновление» не шире окна
        const last = [...document.querySelector(".top").children].pop().getBoundingClientRect();
        return { lockR: Math.round(l.right), flagL: Math.round(f.left), flagR: Math.round(f.right), kbarL: Math.round(k.left), topR: Math.round(last.right),
          over: document.documentElement.scrollWidth - document.documentElement.clientWidth };
      });
      if (r.lockR > r.flagL || r.flagR > r.kbarL || r.topR > width || r.over > 0) throw new Error(`шапка на ${width}px: ` + JSON.stringify(r));
      if (width === 360) await page.screenshot({ path: `${out}/48d-beta-360.png` });
    }
    // Поворот телефона / окно Telegram Desktop: название выбирает размер при отрисовке,
    // а шапку никто не вызывал — после широкого окна оно оставалось крупным и теснило флаг
    await page.setViewportSize({ width: 844, height: 390 });
    await page.evaluate(() => drawTop());
    await page.setViewportSize({ width: 360, height: 844 });
    await page.waitForTimeout(500);
    const rot = await page.evaluate(() => {
      const box = (sel) => document.querySelector(sel).getBoundingClientRect();
      const l = box(".top .lockup"), f = box(".top .cflag"), k = box(".top .kbar");
      return { lockR: Math.round(l.right), flagL: Math.round(f.left), flagR: Math.round(f.right), kbarL: Math.round(k.left),
        over: document.documentElement.scrollWidth - document.documentElement.clientWidth };
    });
    if (rot.lockR > rot.flagL || rot.flagR > rot.kbarL || rot.over > 0) throw new Error("шапка после поворота: " + JSON.stringify(rot));
    await page.setViewportSize(vp);
    await page.evaluate(() => drawTop());
  });
  // ── WG + обфускатор ──
  await step("обфускатор: клиент ob1 в сети, трафик в карточке", async () => {
    await nav("/wgobf", "[data-name=wgobf]");
    await page.waitForSelector("[data-name=ob1] >> text=онлайн");
    await page.waitForSelector("[data-name=ob1] >> text=↓ 3.0 МБ ↑ 1.0 МБ");
    await shot("50-wgobf");
  });
  await step("обфускатор: маскировка", async () => {
    await page.click(".seg button:has-text('NONE')");
    await page.waitForSelector(".toast >> text=NONE");
  });
  await step("обфускатор: клиент и комплект", async () => {
    await nav("/wgobf/add", "input");
    await page.fill("input", "kn1");
    await page.click("button:has-text('Создать')");
    await page.waitForURL(/#\/wgobf\/client\/kn1$/);
    await page.waitForSelector("text=Ссылка для Keenetic");
    await page.waitForSelector("pre >> text=[instance]");
    await page.waitForSelector("img.qr");
    await page.waitForSelector("[data-name=wgobf-status] >> text=не подключался");
    await shot("51-wgobf-client");
    await page.click("button:has-text('Всё в чат')");
    await page.waitForSelector(".toast >> text=в чате с ботом");
  });
  await step("обфускатор: мониторинг клиента включается и запоминается", async () => {
    await page.click(".card.item:has-text('Мониторинг')");
    await page.waitForSelector(".card.item:has-text('Мониторинг') .switch.on");
    await nav("/wgobf/client/kn1", "text=Ссылка для Keenetic");
    await page.waitForSelector(".card.item:has-text('Мониторинг') .switch.on");
  });
  await step("обфускатор: удалить клиента", async () => {
    await page.click("button:has-text('Удалить клиента')");
    await page.waitForURL(/#\/wgobf$/);
    await page.waitForSelector("[data-name=kn1]", { state: "detached" });
    await page.waitForSelector("[data-name=ob1]");
  });
  await step("обзор: маршруты — два окна, AWG и Phobos, листаются свайпом и вкладками", async () => {
    await nav("/", "[data-name=routes] .ptabs");
    const st = () => page.evaluate(() => {
      const tabs = [...document.querySelectorAll("[data-name=routes] .ptabs button")];
      const sl = [...document.querySelectorAll("[data-name=routes] .ptrack > *")];
      return { tabs: tabs.map((b) => b.textContent.trim()), on: tabs.findIndex((b) => b.classList.contains("on")),
        off: sl.map((x) => x.classList.contains("off")), link: document.querySelector("[data-name=routes] > header .r").textContent.trim(),
        pane: localStorage.getItem("awg-routes-pane") };
    });
    let x = await st();
    if (x.on !== 0 || x.off.join() !== "false,true" || x.link !== "туннели →") throw new Error("сначала окно AWG: " + JSON.stringify(x));
    if (!/^AWG \d+\/\d+$/.test(x.tabs[0]) || x.tabs[1] !== "Phobos 1/1") throw new Error("вкладки: " + JSON.stringify(x.tabs));
    if (!/обфускатор: 1 из 1 в сети/.test(await page.textContent(".head"))) throw new Error("нет обфускатора в подзаголовке");
    // Окно листается только вбок; щипок-масштаб страницы на нём работает (веб-панель в браузере)
    const ta = await page.evaluate(() => getComputedStyle(document.querySelector("[data-name=routes] .pager")).touchAction);
    if (!/pinch-zoom/.test(ta) || !/pan-y/.test(ta)) throw new Error("touch-action окна маршрутов: " + ta);
    // Палец влево по окну — следующее окно: Phobos
    const swipe = (dx, dy) => page.evaluate(([dx, dy]) => {
      const el = document.querySelector("[data-name=routes] .pager"), r = el.getBoundingClientRect();
      const x0 = r.left + r.width / 2, y0 = r.top + 60;
      const t = (x, y) => new Touch({ identifier: 1, target: el, clientX: x, clientY: y });
      const fire = (type, x, y) => el.dispatchEvent(new TouchEvent(type, { bubbles: true, cancelable: true,
        touches: type === "touchend" ? [] : [t(x, y)], changedTouches: [t(x, y)] }));
      fire("touchstart", x0, y0);
      for (let i = 1; i <= 5; i++) fire("touchmove", x0 + dx * i / 5, y0 + dy * i / 5);
      fire("touchend", x0 + dx, y0 + dy);
    }, [dx, dy]);
    await swipe(-30, -120);
    await page.waitForTimeout(450);
    if ((await st()).on !== 0) throw new Error("вертикальный жест перелистнул окно");
    await swipe(-140, 10);
    await page.waitForFunction(() => {
      const sl = document.querySelectorAll("[data-name=routes] .ptrack > *");
      return !sl[1].classList.contains("off") && sl[0].classList.contains("off");
    }, null, { timeout: 3000 });
    x = await st();
    if (x.on !== 1 || x.link !== "обфускатор →" || x.pane !== "w") throw new Error("после свайпа — Phobos: " + JSON.stringify(x));
    const t = await page.textContent("[data-name=wgobf-routes]");
    if (!/1 из 1 клиента в сети/.test(t)) throw new Error("подпись окна: " + t);
    const topo = page.locator("[data-name=wgobf-routes] .topo");
    await topo.locator("text=wgobf0").waitFor();
    // Окно AWG свёрнуто — блок по высоте окна Phobos
    const hh = await page.evaluate(() => [document.querySelector("[data-name=routes] .pager").offsetHeight,
      document.querySelector("[data-name=wgobf-routes]").offsetHeight]);
    if (Math.abs(hh[0] - hh[1] - 6) > 2) throw new Error("высота блока не по окну Phobos: " + hh);
    await shot("51b-overview-wgobf");
    const vp = page.viewportSize();
    await page.setViewportSize({ width: 1366, height: 900 });
    await page.waitForTimeout(400);
    await shot("51c-overview-wgobf-pc");
    await page.setViewportSize(vp);
    await page.waitForTimeout(400);
    // За последнее окно не листается
    await swipe(-140, 0);
    await page.waitForTimeout(450);
    if ((await st()).on !== 1) throw new Error("пролистнул за последнее окно");
    // Узел внизу экрана — под нижней панелью разделов: нажатие событием, тот же обработчик
    await topo.locator(".node[data-c=ob1]").first().dispatchEvent("click");
    await page.waitForURL(/#\/wgobf\/client\/ob1$/);
    await page.waitForSelector("[data-name=wgobf-status] >> text=онлайн");
    // Обзор снова — открыто то же окно; вкладка AWG возвращает маршруты AWG
    await nav("/", "[data-name=routes] .ptabs");
    x = await st();
    if (x.on !== 1 || x.off.join() !== "true,false") throw new Error("окно не запомнилось: " + JSON.stringify(x));
    await page.click("[data-name=routes] .ptabs button:has-text('AWG')");
    await page.waitForFunction(() => !document.querySelector("[data-name=routes] .ptrack > *").classList.contains("off"), null, { timeout: 3000 });
    await page.waitForTimeout(450);
    x = await st();
    if (x.on !== 0 || x.off.join() !== "false,true" || x.pane !== "awg" || x.link !== "туннели →") throw new Error("вкладка AWG: " + JSON.stringify(x));
    // Сенсорный экран без touch-событий (Edge) — тот же жест указателем; мышью не листается
    const pswipe = (dx, type) => page.evaluate(([dx, type]) => {
      const el = document.querySelector("[data-name=routes] .pager"), r = el.getBoundingClientRect();
      const x0 = r.left + r.width / 2, y0 = r.top + 60;
      const fire = (ev, x) => el.dispatchEvent(new PointerEvent(ev, { bubbles: true, cancelable: true, pointerId: 7, pointerType: type,
        isPrimary: true, clientX: x, clientY: y0 }));
      fire("pointerdown", x0);
      for (let i = 1; i <= 5; i++) fire("pointermove", x0 + dx * i / 5);
      fire("pointerup", x0 + dx);
    }, [dx, type]);
    await pswipe(-140, "mouse");
    await page.waitForTimeout(450);
    if ((await st()).on !== 0) throw new Error("мышь перелистнула окно");
    await pswipe(-140, "touch");
    await page.waitForFunction(() => document.querySelectorAll("[data-name=routes] .ptabs button")[1].classList.contains("on"), null, { timeout: 3000 });
    await page.click("[data-name=routes] .ptabs button:has-text('AWG')");
    await page.waitForTimeout(450);
  });

  // ── Бот ──
  await step("бот", async () => { await nav("/bot", "[data-name=bot]"); await page.waitForSelector(".sgrid"); await shot("52-bot"); });
  await step("уведомления", async () => {
    await nav("/bot", "text=Уведомления");
    await page.click("text=Уведомления");
    await page.waitForSelector("h1:has-text('Уведомления')");
    if (await page.locator(".switch.on").count() !== 6) throw new Error("ждали 6 включённых уведомлений");
    await page.click(".card.item >> text=Диск заполнен");
    await page.waitForFunction(() => document.querySelectorAll(".switch.on").length === 5);
    await nav("/bot/alerts", ".switch");
    if (await page.locator(".switch.on").count() !== 5) throw new Error("выключенное уведомление не сохранилось");
    await shot("52a-alerts");
  });
  await step("меню бота в чат", async () => {
    await page.click("#tabbar a:has-text('Ещё')");
    await page.click("#more .mg a:has-text('Меню бота')");
    await page.waitForFunction(() => window.__log.includes("close"));
  });
  await step("админы: отозвать", async () => {
    await nav("/bot/admins", "text=@helper");
    await shot("53-admins");
    await page.click("[data-uid='333']");
    await page.waitForSelector("text=Приглашённых нет");
  });
  await step("админы: приглашение", async () => {
    await page.click("button:has-text('Пригласить')");
    await page.waitForSelector(".sheet pre >> text=/t\\.me\\/toolza_test_bot\\?start=inv_/");
    await shot("54-invite");
    await page.click(".sheet button:has-text('Готово')");
    await page.waitForSelector("text=Погасить приглашения: 1");
  });
  await step("оформление: набор иконок", async () => {
    await nav("/bot/look", "text=Иконки в боте");
    await page.click("button:has-text('Набор TgAndroidIcons')");
    await page.waitForSelector(".toast >> text=Иконки включены");
    await page.waitForSelector(".pill >> text=включены");
    await page.click("button:has-text('Выключить')");
    await page.waitForSelector(".pill >> text=выключены");
  });
  await step("прокси", async () => {
    await nav("/bot/proxy", "input");
    await expectAlert("схема", async () => { await page.fill("input", "1.2.3.4:1080"); await page.click("button:has-text('Сохранить')"); });
    await page.click("button:has-text('Найти на сервере')");
    await page.waitForSelector(".card.empty, .item >> nth=0", { timeout: 60000 });
    await shot("55-proxy");
  });
  await step("Mini App: сертификат на IP", async () => {
    await nav("/bot/app", "text=Сервер панели");
    await shot("56-app");
    await page.click("button:has-text('На IP')");
    await page.waitForSelector("h1:has-text('Сертификат на IP') .pill.ok", { timeout: 60000 });
    // Сервер Mini App перезапускается через секунду после выпуска — дальше идём, когда он снова на месте
    await page.waitForTimeout(3000);
  });
  await step("все разделы — в нижней панели и «Ещё»", async () => {
    await nav("/", ".head h1");
    const labels = await page.evaluate(() => [...document.querySelectorAll("#tabbar a, #more .mg a")].map((a) => a.textContent.trim()));
    for (const t of ["Обзор", "Клиенты", "Туннели", "Сервер", "Диагностика", "Обновление", "Бэкапы", "Обфускатор", "Бот", "Тема"]) {
      if (!labels.some((l) => l.startsWith(t))) throw new Error("нет раздела " + t + ": " + labels.join(", "));
    }
  });

  const log = await page.evaluate(() => window.__log);
  say("ALERTS", JSON.stringify(log.filter((l) => l.startsWith("alert:"))));
  say("ERRORS", JSON.stringify(errors));
  await browser.close();
})();
