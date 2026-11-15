// web_drive.js — веб-панель в Chromium: вход, обзор (ПК и телефон), лента и нижняя панель, клиенты
// с карточкой справа (ПК), скачивание, ссылка на конфиг, аккаунт, выход.
// Запускает test_web.py: node web_drive.js ПОРТ ПУТЬ ЛОГИН ПАРОЛЬ КАТАЛОГ_СКРИНШОТОВ
const { chromium } = require("playwright");
const [port, base, user, password, out] = process.argv.slice(2);
const say = (ok, label) => console.log(`${ok ? "OK" : "FAIL"} ${label}`);
(async () => {
  const browser = await chromium.launch();
  for (const [name, vp, scale] of [["ПК", { width: 1366, height: 860 }, 1], ["телефон", { width: 390, height: 844 }, 2]]) {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: vp, deviceScaleFactor: scale, acceptDownloads: true });
    // Сценарий — про «Классику» (лента и нижняя панель); «Карточки» — отдельным шагом ниже
    await ctx.addInitScript(() => {
      try {
        const v = JSON.parse(localStorage.getItem("awg-look") || "null") || {};
        if (!v.skin) { v.skin = "toolza"; localStorage.setItem("awg-look", JSON.stringify(v)); }
      } catch (_) { /* без localStorage — как есть */ }
    });
    const page = await ctx.newPage();
    page.setDefaultTimeout(20000);
    page.on("pageerror", (e) => console.log(`ERR ${name}: ${e}`));
    page.on("request", (r) => { if (!r.url().startsWith(`https://127.0.0.1:${port}/`)) console.log(`ERR ${name}: внешний запрос ${r.url()}`); });
    const u = `https://127.0.0.1:${port}${base}`;
    const step = async (label, fn) => { try { await fn(); say(true, `${name}: ${label}`); } catch (e) { say(false, `${name}: ${label} — ${String(e).split("\n")[0]}`); } };
    await step("сбой API при старте — понятная ошибка и рабочая форма входа", async () => {
      await page.route(/\/api\/me$/, (route) => route.abort());
      try {
        await page.goto(u, { waitUntil: "domcontentloaded" });
        await page.waitForSelector("form.login .bad:has-text('Нет связи с сервером')");
        if (await page.locator("form.login button").isDisabled()) throw new Error("форма входа заблокирована");
      } finally { await page.unroute(/\/api\/me$/); }
    });
    await step("экран входа", async () => {
      await page.goto(u, { waitUntil: "networkidle" });
      await page.waitForSelector("form.login input[autocomplete=username]");
      await page.screenshot({ path: `${out}/${name}-вход.png` });
    });
    await step("неверный пароль — сообщение, панель не открылась", async () => {
      await page.fill("input[autocomplete=username]", user);
      await page.fill("input[type=password]", "wrong-password");
      await page.click("form.login button");
      await page.waitForSelector("form.login .bad:has-text('Неверный логин или пароль')");
    });
    await step("вход — обзор", async () => {
      await page.fill("input[type=password]", password);
      await page.press("input[type=password]", "Enter");
      await page.waitForSelector(".kpis .kpi");
      await page.waitForSelector(".topo svg .node");
      // ПК, лента с подписями: название — рядом со знаком в ленте; на телефоне — в шапке
      await page.waitForSelector(name === "ПК" ? "#rail a.logo .lockup" : ".top .lockup");
      await page.waitForSelector(".top .cflag svg.flag[aria-label='Нидерланды']");
      await page.waitForTimeout(800);
      await page.screenshot({ path: `${out}/${name}-обзор.png` });
    });
    await step(name === "ПК" ? "лента разделов слева на широком экране" : "нижняя панель разделов на телефоне", async () => {
      const rail = await page.locator("#rail").isVisible(), tabs = await page.locator("#tabbar").isVisible();
      if (rail !== (name === "ПК") || tabs === (name === "ПК")) throw new Error(`#rail=${rail} #tabbar=${tabs}`);
    });
    if (name === "ПК") {
      await step("лента: с подписями, «бутерброд» сворачивает до иконок и обратно, выбор запоминается", async () => {
        await page.waitForSelector("#rail a .lbl >> text=Клиенты");
        if (!await page.evaluate(() => document.body.classList.contains("rail-wide"))) throw new Error("по умолчанию без подписей");
        await page.click("#rail a.burger");
        await page.waitForSelector("#rail a .tip >> text=Клиенты", { state: "attached" });
        if (await page.locator("#rail a .lbl").count()) throw new Error("подписи остались");
        // Узкая лента — название снова в шапке, рядом со знаком в ленте его нет
        await page.waitForSelector(".top .lockup");
        if (await page.locator("#rail .lockup").count()) throw new Error("название осталось в узкой ленте");
        await page.screenshot({ path: `${out}/${name}-лента-узкая.png` });
        await page.reload({ waitUntil: "domcontentloaded" });
        await page.waitForSelector("#rail a .tip >> text=Клиенты", { state: "attached" });
        await page.click("#rail a.burger");
        await page.waitForSelector("#rail a .lbl >> text=Клиенты");
        await page.waitForSelector("#rail a.logo .lockup");
        if (await page.locator(".top .lock").isVisible()) throw new Error("при ленте с подписями название и в шапке");
        // Самая длинная надпись — бета-канал и стрелка обновления: целиком в ленте, не обрезана её краем
        // Меряется в том же вызове: свежий статус с сервера вернул бы прежний канал
        const fit = await page.evaluate(() => {
          const w = [S.version, S.channel, S.update];
          S.version = "v1.2.99"; S.channel = "beta"; S.update = "v9.9.99"; drawTop();
          const l = document.querySelector("#rail a.logo .lockup").getBoundingClientRect(), r = document.querySelector("#rail a.logo").getBoundingClientRect();
          const res = { lockR: Math.round(l.right), linkR: Math.round(r.right), h: Math.round(l.height),
            beta: /beta/.test(document.querySelector("#rail .lockup").getAttribute("aria-label")) };
          window.__railWas = w;
          return res;
        });
        await page.screenshot({ path: `${out}/${name}-лента-бета.png`, clip: { x: 0, y: 0, width: 520, height: 160 } });
        await page.evaluate(() => { [S.version, S.channel, S.update] = window.__railWas; drawTop(); });
        if (!fit.beta || fit.lockR > fit.linkR || fit.h < 18) throw new Error("название в ленте: " + JSON.stringify(fit));
      });
      await step("тема: значок вкладки — знак Тулзы или флаг страны с точкой awg0, выбор запоминается", async () => {
        const isFlag = () => page.evaluate(() => /viewBox="0 0 30 20"/.test(decodeURIComponent(document.getElementById("favicon").getAttribute("href") || "")));
        const waitFlag = (on) => page.waitForFunction((on) =>
          /viewBox="0 0 30 20"/.test(decodeURIComponent(document.getElementById("favicon").getAttribute("href") || "")) === on, on);
        if (await isFlag()) throw new Error("по умолчанию во вкладке флаг, а не знак");
        await page.click(".top button[aria-label='Тема']");
        // Заголовки разделов темы не перекрыты тем, что под ними (кнопки значка вкладки наезжали на свой)
        await page.waitForSelector("[data-name=tab-icon]");
        const overlap = await page.evaluate(() => [...document.querySelectorAll(".tsep")].filter((e) => e.offsetParent)
          .map((e) => { const n = e.nextElementSibling; const a = e.getBoundingClientRect(), b = n ? n.getBoundingClientRect() : null;
            return { t: e.textContent, gap: b ? Math.round(b.top - a.bottom) : 99 }; }).filter((x) => x.gap < 4));
        if (overlap.length) throw new Error("заголовок раздела темы перекрыт: " + JSON.stringify(overlap));
        await page.evaluate(() => document.querySelector("[data-name=tab-icon]").scrollIntoView({ block: "center" }));
        await page.screenshot({ path: `${out}/${name}-тема-значок.png` });
        await page.click("[data-name=tab-icon] button:has-text('Флаг страны')");
        await waitFlag(true);
        await page.keyboard.press("Escape");
        await page.reload({ waitUntil: "domcontentloaded" });
        await page.waitForSelector(".top .cflag");
        await waitFlag(true);
        await page.click(".top button[aria-label='Тема']");
        await page.click("[data-name=tab-icon] button:has-text('Знак Тулзы')");
        await waitFlag(false);
        await page.keyboard.press("Escape");
      });
      await step("шапка: флаг — окно «О сервере» под ним; там же скрыть имя и адрес (и порт на схеме)", async () => {
        await page.waitForSelector(".topo svg [data-srv]");
        const st = await page.evaluate(() => [S.status.host, (S.status.server || {}).endpoint || S.status.ip].filter(Boolean));
        const box = "[data-name=server-info]";
        const open = async (sel) => { await page.click(sel); await page.waitForSelector(box + ".pop"); return page.locator(box).innerText(); };
        if (await page.locator(".top .sib").count()) throw new Error("кнопка «i» лишняя — окно по флагу");
        const t0 = await open(".top .cflag");
        if (!st.length || !st.every((v) => t0.includes(v)) || !t0.includes("Нидерланды")) throw new Error("в окне нет страны, имени или адреса: " + t0);
        const pos = await page.evaluate(() => {
          const b = document.querySelector(".top .cflag").getBoundingClientRect(), p = document.querySelector(".sinfo.pop").getBoundingClientRect();
          return { gap: p.top - b.bottom, left: Math.abs(p.left - b.left) };
        });
        if (pos.gap < 0 || pos.gap > 20 || pos.left > 2) throw new Error("окно не под флагом: " + JSON.stringify(pos));
        await page.screenshot({ path: `${out}/${name}-о-сервере.png` });
        // Скрыть — тут же, окно остаётся открытым; порт на схеме тоже скрыт
        await page.click(`${box} button:has-text('Скрыть адрес')`);
        await page.waitForSelector(`${box} button:has-text('Показать адрес')`);
        const th = await page.locator(box).innerText();
        if (st.some((v) => th.includes(v))) throw new Error("в открытом окне адрес не скрылся: " + th);
        await page.waitForFunction(() => { const n = document.querySelector(".topo svg [data-srv]"); return n && !/:\d/.test(n.textContent); });
        await page.keyboard.press("Escape");
        await page.waitForSelector(box, { state: "detached" });
        // Шапка перерисована переключением — фокус всё равно вернулся на флаг
        if (!await page.evaluate(() => document.activeElement === document.querySelector(".top .cflag"))) throw new Error("после Esc фокус не на флаге");
        // По флагу — то же окно; адрес скрыт и после перезагрузки
        await page.reload({ waitUntil: "domcontentloaded" });
        await page.waitForSelector(".top .cflag");
        const t = await open(".top .cflag");
        if (st.some((v) => t.includes(v)) || !t.includes("скрыт")) throw new Error("не скрыто: " + t);
        await page.click(`${box} button:has-text('Показать адрес')`);
        await page.waitForSelector(`${box} button:has-text('Скрыть адрес')`);
        const back = await page.locator(box).innerText();
        if (!st.every((v) => back.includes(v))) throw new Error("не вернулось: " + back);
        await page.keyboard.press("Escape");
        await page.waitForSelector(box, { state: "detached" });
      });
    }
    await step("палитра команд: Ctrl+K — клиент по имени", async () => {
      await page.keyboard.press("Control+k");
      await page.waitForSelector(".pal.on input");
      await page.keyboard.type("alice");
      await page.waitForSelector(".pal li:has-text('alice')");
      await page.keyboard.press("Enter");
      await page.waitForURL(/#\/client\/alice$/);
    });
    await step(name === "ПК" ? "клиенты на ПК — таблицей, карточка клиента — панелью справа" : "клиенты на телефоне — карточками", async () => {
      await page.goto(u + "#/clients");
      await page.waitForSelector(name === "ПК" ? ".ctable tbody tr[data-name=alice]" : ".ecard[data-name=alice]");
      if (name !== "ПК" && await page.locator(".ctable").count()) throw new Error("таблица на телефоне");
      await page.screenshot({ path: `${out}/${name}-клиенты.png` });
      if (name === "ПК") {
        // Заблокирован лимитом трафика, срок впереди — в таблице срок, а не «истёк»; блокировка по сроку — «истёк»
        const exp = await page.evaluate(() => {
          const rows = S.clients.rows, keep = rows.map((c) => [c.blocked, c.blocked_by, c.expires]);
          rows[0].blocked = true; rows[0].blocked_by = "traffic"; rows[0].expires = Math.floor(Date.now() / 1000) + 20 * 86400;
          const nm = rows[0].name, tx = () => document.querySelector(`tr[data-name="${nm}"] td:nth-child(5)`).textContent;
          S.listRedraw(); const a = tx();
          rows[0].blocked_by = "expire"; S.listRedraw(); const b = tx();
          // Срок прошёл, таймер ещё не заблокировал — как раньше, «истёк» янтарным
          rows[0].blocked = false; rows[0].blocked_by = null; rows[0].expires = Math.floor(Date.now() / 1000) - 60;
          S.listRedraw();
          const td = document.querySelector(`tr[data-name="${nm}"] td:nth-child(5)`);
          const c3 = td.textContent + "|" + (td.getAttribute("style") || "");
          rows.forEach((c, i) => { [c.blocked, c.blocked_by, c.expires] = keep[i]; }); S.listRedraw();
          return [a, b, c3];
        });
        if (/истёк/.test(exp[0]) || !exp[0].trim()) throw new Error("клиент с лимитом трафика и будущим сроком: «" + exp[0] + "»");
        if (!/истёк/.test(exp[1])) throw new Error("заблокированный по сроку должен быть «истёк»: «" + exp[1] + "»");
        if (!/истёк/.test(exp[2]) || !/amber/.test(exp[2])) throw new Error("истёкший, ещё не заблокированный — «истёк» янтарным: «" + exp[2] + "»");
        await page.click("tr[data-name=alice]");
        await page.waitForSelector(".drawer.on .cgrid .a-traf");
        await page.waitForSelector("tr.cur[data-name=alice]");          // список — за панелью, строка подсвечена
        await page.screenshot({ path: `${out}/${name}-клиент.png` });
        await page.keyboard.press("Escape");
        await page.waitForURL(/#\/clients$/);
        await page.waitForFunction(() => !document.querySelector(".drawer.on"), null, { timeout: 5000 })
          .catch(() => { throw new Error("панель не закрылась по Esc"); });
      } else {
        await page.goto(u + "#/client/alice");
        await page.waitForSelector("#app .cgrid .a-traf");
        await page.screenshot({ path: `${out}/${name}-клиент.png` });
      }
    });
    await step("клиенты и скачивание конфига: .conf и рядом ZIP", async () => {
      await page.goto(u + "#/client/alice/qr");
      await page.waitForSelector(".confbtns button:has-text('Скачать .conf')");
      const [dl] = await Promise.all([page.waitForEvent("download"), page.click(".confbtns button:has-text('Скачать .conf')")]);
      if (!/^[\w-]+\.conf$/.test(dl.suggestedFilename())) throw new Error(dl.suggestedFilename());
      const [dz] = await Promise.all([page.waitForEvent("download"), page.click(".confbtns button:has-text('Скачать ZIP')")]);
      if (!/^[\w-]+\.zip$/.test(dz.suggestedFilename())) throw new Error(dz.suggestedFilename());
      const zb = require("fs").readFileSync(await dz.path());
      if (zb.readUInt32LE(0) !== 0x04034b50 || !zb.includes(Buffer.from(dl.suggestedFilename()))) throw new Error("в ZIP нет " + dl.suggestedFilename());
    });
    await step("ссылка на конфиг: QR, «Скачать» — alice.conf (форма со своим Origin), чужим адресам ни запроса, ни referrer; отзыв", async () => {
      const call = (path, body) => page.evaluate(async ([p, b]) => (await fetch(p, { method: "POST",
        headers: { "Content-Type": "application/json" }, body: JSON.stringify(b) })).json(), [base + path, body]);
      const d = await call("api/client/share", { name: "alice" });
      if (!/^https:\/\/127\.0\.0\.1:\d+\/s\/[\w-]{32}$/.test(d.url || "")) throw new Error("ссылка не создана");
      let revoked = false;
      try {
        const sp = await ctx.newPage(), sent = [];
        sp.on("request", (r) => sent.push(r));
        try {
          await sp.goto(d.url);
          await sp.click("#show");
          await sp.waitForSelector("#box:not([hidden])");
          if (!/^data:image\/png;base64,/.test(await sp.getAttribute("#qr", "src") || "")) throw new Error("нет QR");
          const [dl] = await Promise.all([sp.waitForEvent("download"), sp.click("form button")]);
          if (dl.suggestedFilename() !== "alice.conf") throw new Error(dl.suggestedFilename());
          if (!require("fs").readFileSync(await dl.path(), "utf8").startsWith("[Interface]")) throw new Error("в файле не конфиг");
          const post = sent.find((r) => r.method() === "POST" && r.url().endsWith("/file"));
          const origin = post && (await post.allHeaders()).origin;
          if (origin !== `https://127.0.0.1:${port}`) throw new Error("Origin формы «Скачать»: " + origin);
          const ext = sent.filter((r) => !/^(https:\/\/127\.0\.0\.1:\d+\/|data:)/.test(r.url()));
          if (ext.length) throw new Error("внешний запрос со страницы ссылки: " + ext[0].url());
          // Переход по внешней ссылке шапки без rel и target: запрос перехвачен и не уходит; referrer в нём быть не должно
          let hdr = null;
          await sp.route(/^https?:\/\/(?!127\.0\.0\.1[:/])/, async (r) => { hdr = await r.request().allHeaders(); await r.abort(); });
          await sp.evaluate(() => { const a = document.querySelector(".top a"); a.removeAttribute("target"); a.removeAttribute("rel"); a.click(); });
          for (let i = 0; i < 20 && !hdr; i++) await sp.waitForTimeout(100);
          if (!hdr) throw new Error("переход по внешней ссылке не перехвачен");
          if (hdr.referer) throw new Error("на внешний адрес ушёл Referer");
        } finally { await sp.close(); }
        revoked = (await call("api/client/share/revoke", { id: d.id })).ok === true;
        if (!revoked) throw new Error("ссылка не отозвана");
        const gp = await ctx.newPage();
        try {
          const resp = await gp.goto(d.url);
          if (resp.status() !== 404) throw new Error("после отзыва — " + resp.status());
          await gp.waitForSelector("text=Ссылка недействительна");
        } finally { await gp.close(); }
      } finally {
        // Шаг упал раньше — ссылку всё равно отзываем: не оставлять действующую до конца 5 минут
        if (!revoked) await call("api/client/share/revoke", { id: d.id }).catch(() => {});
      }
    });
    await step("сессия кончилась при возврате на открытый экран — форма входа нажимается, в снимок не попадает", async () => {
      await page.goto(u + "#/clients");
      await page.waitForSelector(".clist, .ctable");
      await page.goto(u + "#/");
      await page.waitForSelector(".kpis .kpi");
      await ctx.clearCookies();                       // сессии больше нет — ответ 401
      await page.evaluate(() => { location.hash = "#/clients"; });   // экран из снимка, «reloading»
      await page.waitForSelector("form.login input[autocomplete=username]");
      const st = await page.evaluate(() => [document.getElementById("app").className,
        getComputedStyle(document.querySelector("form.login button")).pointerEvents]);
      if (/reloading/.test(st[0]) || st[1] === "none") throw new Error("форма входа приглушена: " + st);
      await page.fill("input[autocomplete=username]", user);
      await page.fill("input[type=password]", password);
      await page.click("form.login button", { timeout: 5000 });
      await page.waitForSelector(".kpis .kpi");
      const login = await page.evaluate(async () => {
        location.hash = "#/clients";
        await new Promise((r) => setTimeout(r, 30));
        return !!document.querySelector("#app form.login");
      });
      if (login) throw new Error("снимок экрана — форма входа");
      await page.waitForSelector(".clist, .ctable");
    });
    if (name === "ПК") {
      await step("боковая панель при окне 600 px — во всю ширину (снизу), а не 460 px справа", async () => {
        await page.setViewportSize({ width: 600, height: 800 });
        const w = await page.evaluate(() => {
          const d = document.createElement("div");
          d.className = "drawer on";
          document.body.append(d);
          const a = d.getBoundingClientRect();
          d.classList.add("wide");
          const b = d.getBoundingClientRect();
          d.remove();
          return [a.left, a.width, b.left, b.width, innerWidth];
        });
        await page.setViewportSize({ width: 1366, height: 860 });
        if (w[0] !== 0 || w[2] !== 0 || w[1] < w[4] - 20 || w[3] < w[4] - 20) throw new Error("left/width: " + w);
      });
    }
    if (name === "ПК") {
      await step("узкий ПК (1001–1100 px): таблица клиентов не раздвигает страницу, логотип не под плашкой сервера", async () => {
        for (const w of [1001, 1024, 1100]) {
          await page.setViewportSize({ width: w, height: 800 });
          await page.goto(u + "#/clients");
          await page.waitForSelector(".ctable tbody tr[data-name=alice]");
          await page.waitForTimeout(400);
          const r = await page.evaluate(() => {
            const lk = document.querySelector(".top .lockup").getBoundingClientRect(), sv = document.querySelector(".top .srv");
            return [document.documentElement.scrollWidth, innerWidth, lk.right, sv ? sv.getBoundingClientRect().left : 1e9];
          });
          if (r[0] > r[1]) throw new Error(`${w}: страница ${r[0]} > ${r[1]}`);
          if (r[2] > r[3] + 1) throw new Error(`${w}: логотип до ${r[2]}, плашка с ${r[3]}`);
        }
        await page.setViewportSize({ width: 1366, height: 860 });
      });
      await step("выбор нескольких: поиск спрятал выбранного — удалять нечего; плашка над нижней панелью", async () => {
        await page.goto(u + "#/clients");
        await page.waitForSelector(".ctable tbody tr[data-name=alice]");
        await page.click("button:has-text('Выбрать')");
        await page.click(".ctable tbody tr[data-name=alice]");
        await page.waitForSelector(".bar button.btn-danger:not([disabled])");
        await page.fill("input[type=search]", "bob");
        await page.waitForFunction(() => !document.querySelector(".ctable tbody tr[data-name=alice]"));
        const del = await page.evaluate(() => { const b = document.querySelector(".bar button.btn-danger"); return [b.disabled, b.textContent.trim()]; });
        if (!del[0] || /\d/.test(del[1])) throw new Error("скрытый поиском клиент остаётся к удалению: " + del);
        await page.fill("input[type=search]", "");
        await page.setViewportSize({ width: 800, height: 900 });
        await page.waitForTimeout(300);
        const pos = await page.evaluate(() => [document.querySelector(".bar").getBoundingClientRect().bottom,
          document.querySelector("#tabbar").getBoundingClientRect().top]);
        await page.setViewportSize({ width: 1366, height: 860 });
        await page.click(".bar button:has-text('Отмена')");
        if (pos[0] > pos[1] + 1) throw new Error("плашка выбора на нижней панели: " + pos);
      });
    } else {
      await step("длинное имя без пробелов в заголовке не раздвигает страницу", async () => {
        const r = await page.evaluate(() => {
          const t = document.createElement("h1");
          t.textContent = "abcdefghijklmnopqrstuvwxyz012345";
          document.getElementById("app").prepend(t);
          const w = document.documentElement.scrollWidth;
          t.remove();
          return [w, innerWidth];
        });
        if (r[0] > r[1]) throw new Error("страница " + r[0] + " > " + r[1]);
      });
    }
    await step("новый клиент: фокус в поле имени, Enter создаёт", async () => {
      const nm = name === "ПК" ? "enterpc" : "enterph";
      await page.goto(u + "#/add");
      await page.waitForSelector("#app input[placeholder=anna_phone]");
      await page.waitForFunction(() => document.activeElement && document.activeElement.placeholder === "anna_phone", null, { timeout: 3000 })
        .catch(() => { throw new Error("фокус не в поле имени"); });
      await page.keyboard.type(nm);
      await page.keyboard.press("Enter");
      await page.waitForURL(new RegExp(`#/client/${nm}/qr$`), { timeout: 10000 });
    });
    await step("ошибка — листом панели с текстом, а не окном браузера; Enter в переименовании", async () => {
      const dialogs = [];
      const onDialog = (d) => { dialogs.push(d.message()); d.dismiss().catch(() => {}); };
      page.on("dialog", onDialog);
      await page.goto(u + "#/client/alice/rename");
      await page.waitForSelector("input[maxlength='32']");
      await page.fill("input[maxlength='32']", "bad name!");
      await page.press("input[maxlength='32']", "Enter");
      await page.waitForSelector(".sheet[role=dialog] h3:has-text('Имя: латиница')", { timeout: 5000 })
        .catch(() => { throw new Error("нет листа с ошибкой; окна браузера: " + JSON.stringify(dialogs)); });
      page.off("dialog", onDialog);
      if (dialogs.length) throw new Error("окно браузера: " + dialogs.join(" | "));
      await page.keyboard.press("Escape");
      await page.waitForFunction(() => !document.querySelector(".sheet-bg"));
    });
    if (name === "ПК") {
      await step("окна поверх страницы: фокус внутрь, Tab не уходит под окно, закрыли — фокус к кнопке", async () => {
        await page.goto(u + "#/clients");
        await page.waitForSelector(".ctable tbody tr[data-name=alice]");
        await page.click(".head button:has-text('Новый клиент')");
        await page.waitForSelector(".sheet[role=dialog][aria-modal=true]");
        const inSheet = () => page.evaluate(() => !!(document.activeElement && document.activeElement.closest(".sheet")));
        if (!await inSheet()) throw new Error("фокус не в листе");
        for (let i = 0; i < 5; i++) await page.keyboard.press("Tab");
        if (!await inSheet()) throw new Error("Tab увёл фокус из листа");
        await page.keyboard.press("Escape");
        await page.waitForFunction(() => !document.querySelector(".sheet-bg"));
        const back = await page.evaluate(() => (document.activeElement || {}).textContent || "");
        if (!/Новый клиент/.test(back)) throw new Error("фокус после закрытия: " + back);
        await page.keyboard.press("Control+k");
        await page.waitForSelector(".pal.on [role=dialog]");
        for (let i = 0; i < 4; i++) await page.keyboard.press("Tab");
        if (!await page.evaluate(() => !!document.activeElement.closest(".pal"))) throw new Error("Tab увёл фокус из палитры");
        await page.keyboard.press("Escape");
        await page.click("tr[data-name=alice]");
        await page.waitForSelector(".drawer.on[role=dialog]");
        if (!await page.evaluate(() => !!document.activeElement.closest("#drawer"))) throw new Error("фокус не в карточке справа");
        await page.keyboard.press("Escape");
        await page.waitForURL(/#\/clients$/);
      });
    }
    await step("«Карточки»: шрифт свой, туннели и клиенты карточками" + (name === "ПК" ? ", лента на месте" : ", меню в шапке"), async () => {
      await page.evaluate(() => { const v = JSON.parse(localStorage.getItem("awg-look")); v.skin = "cards"; localStorage.setItem("awg-look", JSON.stringify(v)); });
      await page.goto(u + "#/tunnels");
      await page.reload({ waitUntil: "domcontentloaded" });
      await page.waitForSelector(".kstats");
      await page.waitForSelector(".kcard[data-tunnel=exits]");
      const st = await page.evaluate(() => ({ rail: !!document.querySelector("#rail a"), tabs: getComputedStyle(document.getElementById("tabbar")).display,
        burger: !!document.querySelector(".top .kburger"), over: document.documentElement.scrollWidth - document.documentElement.clientWidth }));
      if (name === "ПК" ? !st.rail || st.burger : st.rail || !st.burger || st.tabs !== "none") throw new Error(JSON.stringify(st));
      if (st.over > 0) throw new Error("страница шире экрана на " + st.over + " px");
      await page.waitForFunction(() => [...document.fonts].some((f) => f.family.indexOf("IBM Plex") >= 0 && f.status === "loaded"));
      await page.screenshot({ path: `${out}/${name}-карточки-туннели.png`, fullPage: true });
      await page.goto(u + "#/clients");
      await page.waitForSelector(".kstats");
      if (name === "ПК") await page.waitForSelector(".ktools .seg button[aria-label='Таблица']");
      await page.screenshot({ path: `${out}/${name}-карточки-клиенты.png`, fullPage: true });
      await page.evaluate(() => { const v = JSON.parse(localStorage.getItem("awg-look")); v.skin = "toolza"; localStorage.setItem("awg-look", JSON.stringify(v)); });
      await page.reload({ waitUntil: "domcontentloaded" });
      await page.waitForSelector("#app h1");
    });
    await step("аккаунт: смена пароля и сессии", async () => {
      await page.goto(u + "#/account");
      await page.waitForSelector("text=Сменить пароль");
      await page.waitForSelector("text=Последние события");
      await page.screenshot({ path: `${out}/${name}-аккаунт.png`, fullPage: true });
    });
    await step("аккаунт: доступ по адресам — сохранить, неверный адрес, обратно «для всех»", async () => {
      await page.waitForSelector(".acc-access .seg button.on:has-text('Для всех')");
      await page.click(".acc-access .seg button:has-text('По адресам')");
      await page.waitForSelector(".acc-access textarea");
      // Стенд — тот же компьютер: «с самого сервера», свой адрес добавлять незачем
      await page.waitForSelector(".acc-access >> text=с самого сервера");
      if (await page.$(".acc-access button:has-text('Мой адрес')")) throw new Error("кнопка «Мой адрес» для 127.0.0.1");
      await page.fill(".acc-access textarea", "198.51.100.7, 203.0.113.0/24");
      await page.click(".acc-access button:has-text('Сохранить доступ')");
      // Экран перерисован с сервера: список — в виде, в каком его сохранил awg2
      await page.waitForFunction(() => {
        const t = document.querySelector(".acc-access textarea");
        return t && t.value === "198.51.100.7/32, 203.0.113.0/24";
      }).catch(async () => { throw new Error("после сохранения: " + await page.inputValue(".acc-access textarea")); });
      await page.waitForSelector(".acc-access .seg button.on:has-text('По адресам')");
      await page.waitForSelector(".acc-access >> text=Изнутри VPN");
      await page.screenshot({ path: `${out}/${name}-аккаунт-доступ.png`, fullPage: true });
      await page.fill(".acc-access textarea", "300.1.1.1");
      await page.click(".acc-access button:has-text('Сохранить доступ')");
      await page.waitForSelector(".sheet >> text=300.1.1.1");
      await page.keyboard.press("Escape");
      await page.waitForFunction(() => !document.querySelector(".sheet-bg"));
      await page.click(".acc-access .seg button:has-text('Для всех')");
      await page.click(".acc-access button:has-text('Сохранить доступ')");
      await page.waitForFunction(() => !document.querySelector(".acc-access textarea"));
      await page.waitForSelector("text=доступ изменён");
    });
    await step("аккаунт: длинный адрес IPv6 на 320 px — без горизонтальной прокрутки", async () => {
      const vp = page.viewportSize();
      await page.setViewportSize({ width: 320, height: vp.height });
      await page.route(/\/api\/web\/account$/, async (r) => {
        const rr = await r.fetch(), j = await rr.json();
        j.access = Object.assign({}, j.access, { mode: "ip", me: "2001:0db8:85a3:0000:0000:8a2e:0370:7334", me_vpn: false, me_self: false });
        r.fulfill({ response: rr, body: JSON.stringify(j) });
      });
      try {
        await page.goto(u + "#/account");
        await page.reload({ waitUntil: "domcontentloaded" });
        await page.waitForSelector(".acc-access button:has-text('Мой адрес')");
        const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        if (over > 0) throw new Error("страница шире экрана на " + over + " px");
      } finally { await page.unroute(/\/api\/web\/account$/); await page.setViewportSize(vp); }
    });
    await step("выход — снова экран входа, API закрыт; во вкладке снова знак Тулзы, не флаг сервера", async () => {
      const flagNow = () => page.evaluate(() => /viewBox="0 0 30 20"/.test(decodeURIComponent(document.getElementById("favicon").getAttribute("href") || "")));
      await page.evaluate(() => { LOOK.tab = "flag"; applyLook(true); });
      await page.waitForFunction(() => S.status && S.status.country);
      if (!await flagNow()) throw new Error("перед выходом флаг не показан");
      await page.click("#app button:has-text('Выйти')");
      await page.waitForSelector("form.login");
      if (await flagNow()) throw new Error("на экране входа во вкладке флаг страны сервера");
      await page.goto(u + "#/clients");
      await page.waitForSelector("form.login");
    });
    await ctx.close();
  }
  await browser.close();
})();
