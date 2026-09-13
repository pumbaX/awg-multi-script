<div align="center">

# **AWG Toolza**

**Менеджер AmneziaWG 2.0 / 3.0 / 3.1** — одной командой.<br>
3 уровня обфускации, 9 профилей мимикрии (QUIC / cURL QUIC+ECH / DNS / STUN / WebRTC / SIP / NTP / RTP / SSDP), локальный CPS-генератор на базе payloadGen, **Warp туннель Cloudflare**, DPI-тест.

<br>

[![License: MIT](https://img.shields.io/badge/License-MIT-ffffff?style=flat-square&labelColor=000000)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Ubuntu%2024%20%2F%20Debian%2012%2B-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Protocol](https://img.shields.io/badge/AWG-2.0%20%2F%203.0%20%2F%203.1-00d4ff?style=flat-square)](#)
[![Version](https://img.shields.io/badge/version-v0.8.25-ff6b00?style=flat-square)](#)

<br>

[![Boosty](https://img.shields.io/badge/Boosty-Поддержать-F15F2C?style=for-the-badge&logo=boost&logoColor=white)](https://boosty.to/awgtoolza/donate)
[![YooMoney](https://img.shields.io/badge/YooMoney-Поддержать-8B3FFC?style=for-the-badge&logo=yandex&logoColor=white)](https://yoomoney.ru/to/4100119521619579)

</div>

---

## Быстрый старт

```bash
sudo curl -fsSL https://raw.githubusercontent.com/pumbaX/awg-multi-script/main/awg2.sh -o /usr/local/bin/awg2 && sudo chmod +x /usr/local/bin/awg2 && sudo awg2
```

Запуск в любой момент:
```bash
sudo awg2
```

История версий — [CHANGELOG.md](CHANGELOG.md).

### Канал обновлений

По умолчанию скрипт обновляется из основного репозитория (`pumbaX/awg-multi-script`) —
это стабильный канал. Ранние сборки живут в бета-репозитории
(`genaRijoff/awg-multi-script`): `sudo awg2` → **8) Обновить скрипт** → **2) Переключиться
на бета-канал**. Выбор сохраняется в `/var/lib/awg2/channel` и переживает обновление;
вернуться на стабильный канал можно там же (если бета-версия окажется новее, обновление
предложит откат). Разовый запуск на бета-канале без сохранения:
`AWG2_UPDATE_CHANNEL=beta sudo -E awg2`.

Канал влияет и на Telegram-бота: установка из пункта 6 берёт его код из того же
репозитория.

---

## Требования к клиентам

Версия протокола задаётся на **весь сервер**, поэтому клиент обязан её понимать:

| версия сервера | что нужно клиенту |
|---|---|
| AWG 2.0 | любой клиент AmneziaWG |
| AWG 3.1 | **AmneziaVPN 5.0.1.5 или новее** |

Клиент старше 5.0.1.5 не знает ключей `RandomTrailers` и `DisableCookies` и
отказывается импортировать конфиг с незнакомым ключом **целиком** — не
«пропускает строку», а отвергает весь файл. Если среди ваших клиентов есть
те, кого обновить нельзя, поднимите им отдельный сервер на 2.0.

Отдельно: `HeaderProtectionKey`, `S1`-`S4`, `H1`-`H4` и `RandomTrailers`
обязаны совпадать у сервера и клиента побайтово. Расхождение проявляется
молчанием — в `awg show` просто никогда не появится `latest handshake`, без
единой строки в логах.

---

## Обновление ядерного модуля

`awg2` ставит модуль `amneziawg` один раз при установке сервера. Апстрим выпускает
теги с фиксами (например `v3.1.20260827` — инициализация `header_protection.lock`),
и обновиться до конкретного тега, не переустанавливая сервер, помогает отдельный
скрипт:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/pumbaX/awg-multi-script/main/awg-mod-update.sh -o /usr/local/bin/awg-mod-update && sudo chmod +x /usr/local/bin/awg-mod-update && sudo awg-mod-update
```

Запуск в любой момент:
```bash
sudo awg-mod-update              # меню
sudo awg-mod-update --status     # что стоит сейчас
sudo awg-mod-update --latest     # обновить до последнего тега
```

Перед удалением старой сборки скрипт делает резервную копию исходников и пробную
компиляцию новых: если новый код не собирается под это ядро, старая сборка остаётся
на месте. Перезагрузка модуля — отдельный подтверждаемый шаг (туннель ложится на
несколько секунд); если SSH идёт через сам туннель, перезапуск уходит в `systemd-run`,
чтобы не потерять сервер. Есть откат из резервной копии.

---

## Туннели: Xray, tun2socks, AWG-exit

Пункт **5) Туннели и DNS** — Warp, DNS, каскад портов, плюс:

- **Xray** — outbounds из ссылок `vless://` / `vmess://` / `hysteria2://`,
  балансировка (random / roundRobin / leastPing / leastLoad), выбор того, кто
  из клиентов идёт в туннель. Трафик уходит через интерфейс `xray0`.
- **tun2socks** — весь трафик AWG-клиентов в готовый SOCKS5
  (`awg-tun2socks.service`)
- **AWG exit-ноды** — каскад через другие AWG-серверы, ECMP-балансировка,
  можно назначить клиенту конкретную ноду (пункт 6 → `e`): один выходит
  через одну страну, другой — через другую
  между ними, per-client переключатели

Одновременно может быть активен только один из Warp / Xray / tun2socks / exit —
скрипт проверяет это при включении каждого.

Перед тем как увести клиентов в туннель, скрипт проверяет, что трафик по нему
реально ходит: не ходит — туннель не включается и маршруты клиентов не
меняются. Если что-то всё же пошло не так, **5 → 7) Аварийный сброс** гасит
все туннели и возвращает клиентов на прямой маршрут, ничего не удаляя из
настроек.

Про `xray0`: апстримный XTLS/Xray-core не умеет inbound `tun`, поэтому скрипт
спрашивает у самого бинаря (`xray run -test`), есть ли TUN-вход. Если нет —
Xray отдаёт SOCKS5 на `127.0.0.1:10808`, а `xray0` поднимает поверх него
tun2socks. Снаружи разницы нет; режим виден в статусе туннеля.

Ссылка `hysteria2://` принимается только сборкой Xray с поддержкой этого
протокола — в апстримном XTLS/Xray-core её нет. Скрипт проверяет каждый
outbound на самом бинаре до записи в конфиг и не даёт положить туда то, что
Xray не примет. Разобраться с уже сломанным конфигом помогает
**5 → 4 → 9) Проверить конфиг** — покажет причину и предложит убрать
неподдерживаемые outbounds.

CLI:

```bash
sudo awg2 --auto                  # неинтерактивная установка сервера и client1
sudo awg2 --add-client имя        # добавить клиента
sudo awg2 --interactive           # меню даже на чистом сервере
sudo awg2 --help                  # список аргументов
```

`AUTOINSTALL=1` — то же, что `--auto`.


### Бот не подключается к Telegram

На части серверов (чаще всего в РФ) провайдер блокирует адрес, который DNS
отдаёт для `api.telegram.org` — а отдаёт он ровно один. Переключиться не на
что, и бот молча не отвечает.

С версии 2.2.3 бот сам подмешивает к ответу DNS известные адреса Telegram и
берёт тот, что отвечает. Настройки для этого не нужно.

Если режут не по IP, нужен прокси: **пункт 6 → 6 «Прокси до Telegram»**. Меню
само найдёт прокси, уже поднятые на сервере (SOCKS-вход Xray из пункта 5),
предложит их списком, проверит связь перед сохранением и перезапустит бота.
Подойдёт и любой сторонний SOCKS5 или HTTP-прокси.

Туннель из пункта 5 после перезагрузки не поднимается сам, поэтому прокси на
`127.0.0.1` временно исчезает. Бот это переживает: не достучавшись до прокси,
он идёт напрямую с запасными адресами и пишет причину в лог. Когда туннель
подняли обратно — `systemctl restart awg-bot`.

Руками — строка в `/etc/awg-bot.conf`, затем `systemctl restart awg-bot`:

```
BOT_PROXY=socks5://127.0.0.1:10808
```

Проверить, что запасные адреса подключились:

```
journalctl -u awg-bot -n 50 | grep 'Запасные адреса'
```

Строка `Запасные адреса Telegram подключены (5 шт.)` — всё на месте.

---

## 🤖 Telegram бот

Опционально — Telegram бот для управления сервером со смартфона: inline-меню с теми же возможностями, что и в консоли.

**Установка:**

Проще всего — через главное меню: `sudo awg2` → **6) Telegram-бот** → Установить.

Или вручную:

```bash
sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/pumbaX/awg-multi-script/main/awg-bot-install.sh -o /tmp/awg-bot-install.sh && bash /tmp/awg-bot-install.sh'
```

В процессе установщик спросит:
1. **Bot Token** — получи у [@BotFather](https://t.me/BotFather): `/newbot` → имя → токен
2. **Telegram ID** — твой ID для авторизации (узнать через [@userinfobot](https://t.me/userinfobot))

После установки бот стартует как systemd-сервис (`awg-bot.service`) и сам поднимается при перезагрузке.

---

## Импорт на клиенте

[**AmneziaVPN**](https://amnezia.org) (Android / iOS / macOS / Windows / Linux):
- **QR** — Клиенты → 4, сканируй с терминала
- **Текст** — Клиенты → 5 для больших конфигов (с I1–I5) → копируй в буфер
- **Файл** — `Добавить туннель → Из файла` → передай `/root/<имя>_awg2.conf` через scp

[**AmneziaWG**](https://github.com/amnezia-vpn/amneziawg-windows-client) — официальное приложение протокола AmneziaWG:
- [**Android**](https://play.google.com/store/apps/details?id=org.amnezia.awg)
- [**iOS**](https://apps.apple.com/app/amneziawg/id6478942365)
- [**Windows**](https://github.com/amnezia-vpn/amneziawg-windows-client/releases/tag/2.0.0)

[**Keenetic**](https://docs.amnezia.org/documentation/instructions/keenetic-os-awg) — KeeneticOS 4.x+ или AWG Manager на Entware


---

## Проверка конфига

Проверить свой `.conf` на валидность, DPI-стойкость и оптимальность параметров можно через [AWG Analyzer](https://pumbax.github.io/awg-analyzer/) — полностью локальный JS-инструмент.

---

## Поддержать

**Boosty:** https://boosty.to/awgtoolza/donate

**YooMoney:** https://yoomoney.ru/to/4100119521619579

| Сеть | Адрес |
|---|---|
| USDT TRC20 | `TN2rQAsGNHQr8wnneKRD14UMX629D2Ca5q` |
| USDT ERC20 | `0x721845234eeC44e0a9BaE78402965828C1bc6c57` |
| USDT TON | `UQCwj-RY2a4BH7sIDDeLb77XRaPDq0mb1FVwyC4UaOGbLMYy` |
| TON | `UQCdQtJO4CF0Lyeb93X2zdeWeAcDJ-ieBC3AaL7LIqWfMBg3` |

---

<div align="center">

*Отдельная благодарность [AWG-Manager](https://t.me/awgmanager)*

<br>

*Сообщество [AWG-Toolza](https://t.me/awgToolza)*

**AWG Toolza v0.8.25** · MIT License

</div>
