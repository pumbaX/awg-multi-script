<div align="center">

# **AWG Toolza**

**Менеджер AmneziaWG 2.0** -  одной командой.<br>
3 уровня обфускации, профили мимикрии (TLS / DNS / SIP / QUIC), локальный CPS-генератор, **Warp туннель Cloudflare**, DPI-тест.

<br>

[![License: MIT](https://img.shields.io/badge/License-MIT-ffffff?style=flat-square&labelColor=000000)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Ubuntu%2024%20%2F%20Debian%2012%2B-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Protocol](https://img.shields.io/badge/AWG-2.0%20only-00d4ff?style=flat-square)](#)
[![Version](https://img.shields.io/badge/version-6.9.0-ff6b00?style=flat-square)](#)

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

--- 
## ☁ Warp туннель Cloudflare

Обход блокировки IP сервера в РФ. Когда ТСПУ блокирует IP Hetzner/OVH — заворачиваем выходной трафик через Cloudflare.

```
Клиент РФ → AWG → твой сервер → Cloudflare → интернет
```

SSH и серверный трафик идут напрямую — не через Warp.

**Меню Warp (Туннели и DNS → Warp):**

```
1) Установить wgcf и зарегистрировать Warp
2) Активировать Warp+ (лицензионный ключ)
3) Включить туннель
4) Выключить туннель
5) Перегенерировать профиль
6) Управление клиентами в Warp     ← кто через Warp, кто напрямую
7) Health-check + auto-failover    ← если упал — direct routing
8) Импорт wgcf-profile.conf        ← если регистрация блокируется
9) Поиск рабочего endpoint         ← если 2408 режется DPI
d) Удалить Warp полностью
```

**Где взять Warp+ ключ:**
- 🥈 Приложение **1.1.1.1** → Аккаунт → Ключ

**Если Warp не подключается на РФ хостинге:**
1. `Туннели и DNS → Warp → 8` — импорт готового профиля через Google Cloud Shell
2. `Туннели и DNS → Warp → 9` — автоматический поиск рабочего endpoint
3. Если ничего не помогло — провайдер режет UDP к Cloudflare, нужен другой хостинг


## Меню

Меню двухуровневое: 8 категорий, у каждой своё подменю.

```
╔══════════════════════════════════════════════╗
║    AWG Toolza v6.9.0                         ║
║   AWG 2.0 — TLS / DNS / SIP / QUIC мимик     ║
║              + Warp туннель Cloudflare       ║
╚══════════════════════════════════════════════╝
  IP сервера : 100.20.38.41
  Порт       : 41300
  Интерфейс  : ● активен
  Профиль    : standard
  Клиентов   : 21

  1)  Сервер          — установка
  2)  Клиенты         — управление
  3)  Диагностика     — тест, домены
  4)  Бекапы          — создать, восстановить
  5)  Туннели и DNS   — Warp, DNS, каскад
  6)  Telegram-бот    — управление ботом
  7)  Удаление и сброс
  8)  Обновить скрипт — загрузить с GitHub

   0) Выход
```

**1) Сервер**
```
1) Установка зависимостей и AmneziaWG
2) Создать сервер + первый клиент (выбор профиля и мимикрии)
3) Перезапустить awg0
4) Проверить и починить awg0 (авторемонт)
5) Сбросить настройки сервера (чистая переустановка)
```

**2) Клиенты**
```
1) Добавить клиента
2) Переименовать клиента
3) Удалить клиента
4) Показать QR клиента
5) Показать конфиг клиента (текст)
6) Создать N клиентов (массово)
7) Срок действия клиента (auto-suspend по истечении)
8) Активность клиентов
```

**3) Диагностика**
```
1) Проверить домены из пулов (ping)
2) Тест DPI мимикрии (захват CPS пакета)
```

**4) Бекапы** — создать (`~/awg_backup/`) / восстановить.

**5) Туннели и DNS** — Warp туннель Cloudflare, шифрованный DNS, каскад на зарубежный VPS.

**7) Удаление и сброс** — очистить клиентов / удалить всё.

---

## Профили и мимикрия

При создании сервера (Сервер → 2) выбирается профиль:

| Профиль | Обфускация | Мимикрия I1 |
|---|---|---|
| **Lite** | базовая | DNS (icloud.com) |
| **Standard** | сбалансированная | **TLS ClientHello** |
| **Pro** | на выбор (без I1 / +I1 / +I1-I5) | TLS / DNS / SIP / QUIC |

Профили мимикрии (Pro, выбор уровня I1–I5):

- **TLS** — браузерный ClientHello (Chrome-like, рандомный SNI из пула). **Рекомендуется в РФ 2026** — выглядит как обычный заход на сайт, DPI его не режет.
- **DNS** — DNS Query c EDNS0, рандомный TXID. Компактный, надёжный.
- **SIP** — REGISTER-запрос (VoIP мимикрия).
- **QUIC** — Chrome-like Initial 1200B + Short Header. ⚠ В РФ 2026 ловят по сигнатуре Initial-пакета — используй осознанно.

> CPS-пакеты I1–I5 — это **клиентские** параметры. В серверный `awg0.conf` они не пишутся (там только Jc/Jmin/Jmax/S/H). Разные клиенты могут иметь разную мимикрию на одном сервере.

---

## 🔐 Шифрованный DNS (Туннели и DNS → DNS-шифрование)

Все DNS-запросы клиентов идут через DoH (DNS-over-HTTPS) к Cloudflare / Google / Quad9 с проверкой DNSSEC.

```
Клиент → AWG → DNAT iptables → dnscrypt-proxy → DoH → Cloudflare/Google/Quad9
                (порт 53)        (127.0.0.1:5300)        (HTTPS зашифрованно)
```

**Что даёт:**
- Защита от DNS-leak (даже если в конфиге клиента указан 8.8.8.8 — запрос пойдёт через шифрованный канал)
- Провайдер сервера не видит какие домены резолвятся
- DNSSEC защищает от подмены ответов
- No-logging резолверы

**Меню:**
```
1) Включить (установить + настроить)
2) Перезапустить сервис
3) Логи
4) Сменить upstream (Cloudflare / Google / Quad9 / комбинации)
5) Выключить и удалить
```

## 🤖 Telegram бот

Опционально — Telegram бот для управления сервером со смартфона. Добавляешь токен от @BotFather, и бот даёт inline-меню с теми же возможностями что и SSH.

**Что умеет:**
- Список клиентов со статусом (🟢/🟡/🔴/⚫ онлайн, трафик, последний handshake), с пагинацией (◀️ ▶️) — корректно работает при сотнях клиентов
- 🚨 **Сигнал при отвале клиента** — если онлайн-клиент пропадает из сети, бот шлёт уведомление со звуком (имя, IP, заметка, время пропажи). Чтобы не пропустить упавшее резервирование
- Добавить клиента — выбор профиля мимикрии прямо в боте
- Получить QR-код / текст / .conf файл по любому клиенту
- 📝 Заметки к клиентам (произвольный текст, кликабельная ссылка если это URL)
- ☁️ Вкл/выкл WARP для клиента прямо из карточки (синхронизировано с awg2)
- ⏰ Срок действия клиента (auto-suspend по истечении)
- Удалить клиента с подтверждением
- Статус сервера (uptime AmneziaWG, количество подключений, нагрузка)

**Установка:**

Проще всего — через главное меню: `sudo awg2` → **6) Telegram-бот** → Установить.

Или вручную:

```bash
sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/pumbaX/awg-multi-script/main/awg-bot-install.sh -o /tmp/awg-bot-install.sh && bash /tmp/awg-bot-install.sh'
```

**Запуск:**
```bash
sudo bash /tmp/awg-bot-install.sh
```

В процессе установщик спросит:
1. **Bot Token** — получи у [@BotFather](https://t.me/BotFather): `/newbot` → имя → токен
2. **Telegram ID** — твой ID для авторизации (узнать через [@userinfobot](https://t.me/userinfobot))

После установки бот стартует как systemd-сервис (`awg-bot.service`) и сам поднимается при перезагрузке.

**Обновление:** меню **6) Telegram-бот** → Обновить (или пункт 2 в меню установщика). Свежая версия тянется с GitHub автоматически, токен и chat_id сохраняются.

**Команды бота:**
- `/start` — главное меню (inline-кнопки)
- `/status` — статус сервера
- `/help` — справка
- `/id` — узнать свой Telegram ID

**Управление сервисом:**
```bash
sudo systemctl status awg-bot       # статус
sudo systemctl restart awg-bot      # перезапуск
sudo journalctl -u awg-bot -f       # живые логи
```

---

## Файлы

| Путь | Назначение |
|---|---|
| `/etc/amnezia/amneziawg/awg0.conf` | Серверный конфиг |
| `/root/<имя>_awg2.conf` | Клиентские конфиги |
| `/var/log/awg-Toolza.log` | Лог |
| `~/awg_backup/` | Бекапы |
| `/tmp/awg_domain_cache.txt` | Кэш проверки доменов (пункт 6) |
| `/usr/local/bin/awg-bot.py` | Код Telegram-бота |
| `/etc/awg-bot.conf` | Токен и chat_id бота |
| `/etc/systemd/system/awg-bot.service` | Сервис бота |
| `/var/log/awg-bot.log` | Лог бота |


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

Проверить свой `.conf` на валидность, DPI-стойкость и оптимальность параметров можно через [AWG Analyzer](https://pumbax.github.io/awg-analyzer/) — полностью локальный JS-инструмент:

- Детект версии (WireGuard / AWG 1.0 / 1.5 / 2.0) + уровень обфускации
- Глубокий разбор I1-I5 (валидность `<b 0x...>`, лимит `<r>`, протокол)
- Проверка H1-H4 sub-квадрантов (12/12 = идеал)
- Security / Stealth / DPI score
- Рекомендации CRIT/HIGH/MED/LOW + пошаговый upgrade path

Анализатор обновлён под параметры v6.2 — проверки по официальному мануалу AmneziaWG.

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

**AWG Toolza v6.9.0** · MIT License

</div>
