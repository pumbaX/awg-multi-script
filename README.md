<div align="center">

# **AWG Toolza**

**Менеджер AmneziaWG 2.0** — VPN с DPI-обходом одной командой.<br>
3 уровня обфускации, 5 профилей мимикрии, локальный CPS-генератор, **Warp туннель Cloudflare**, DPI-тест.

<br>

[![License: MIT](https://img.shields.io/badge/License-MIT-ffffff?style=flat-square&labelColor=000000)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Ubuntu%2024%20%2F%20Debian%2012%2B-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Protocol](https://img.shields.io/badge/AWG-2.0%20only-00d4ff?style=flat-square)](#)
[![Version](https://img.shields.io/badge/version-6.7-ff6b00?style=flat-square)](#)

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
## ☁ Что нового в v6.7 — Warp туннель Cloudflare

**Главная фича** — Warp туннель Cloudflare для обхода блокировки IP сервера в РФ. Когда ТСПУ блокирует IP Hetzner/OVH — заворачиваем выходной трафик через Cloudflare, и блокировки перестают мешать.

**Архитектура split-tunnel:**
```
Клиент РФ → AWG → твой сервер → Cloudflare → интернет
```

Внешний IP меняется с твоего хостинга на Cloudflare. SSH и серверный трафик идут напрямую — не через Warp.

**Меню Warp (пункт 15):**
```
1) Установить wgcf и зарегистрировать Warp (бесплатный)
2) Активировать Warp+ (лицензионный ключ из 1.1.1.1)
3) Включить туннель
4) Выключить туннель
5) Перегенерировать профиль
7) Управление клиентами в Warp        ← кто через Warp, кто напрямую
8) Health-check (вкл/выкл авто-failover) ← если Warp упал — direct routing
6) Удалить Warp полностью
```

**Где взять Warp+ ключ (бесплатно):**
- Приложение **1.1.1.1** → Шестерёнка → Аккаунт → Ключ
- Реферальная программа в приложении (до 25 ГБ)
- **Cloudflare Zero Trust** на dash.cloudflare.com — безлимит до 50 пользователей


## Меню

```
╔══════════════════════════════════════════════╗
║    AWG Toolza v6.7                           ║
║   AWG 2.0 — QUIC / WebRTC / SIP / DNS        ║
║              + Warp туннель Cloudflare       ║
╚══════════════════════════════════════════════╝
  IP сервера : 100.20.38.41
  Порт       : 41300
  Интерфейс  : ● активен
  Клиентов   : 21

  ▸ Основные:
  1)  Установка зависимостей и AmneziaWG
  2)  Создать сервер + первый клиент (с мимикрией)
  3)  Управление клиентами
  4)  Активность клиентов

  ▸ Утилиты:
  5)  Перезапустить awg0
  6)  Проверить домены из пулов (ping)
  7)  Тест DPI мимикрии (захват CPS пакета)

  ▸ Бекапы:
  8)  Создать бекап (~/awg_backup/)
  9)  Восстановить из бекапа

  ▸ Опасная зона:
  10) Очистить всех клиентов (без удаления сервера)
  11) Сбросить настройки сервера (чистая переустановка)
  12) Удалить всё (пакеты + конфиги)

  ▸ Сервис:
  13) Проверить и починить awg0 (авторемонт)
  14) Обновить скрипт с GitHub

  ▸ Warp туннель:
  15) Warp туннель  ● включен / ○ выключен / ○ не настроен

   0) Выход
```

## 🤖 Telegram бот

Опционально — Telegram бот для управления сервером со смартфона. Добавляешь токен от @BotFather, и бот даёт inline-меню с теми же возможностями что и SSH.

**Что умеет:**
- Список клиентов со статусом (онлайн/offline, трафик, последний handshake)
- Добавить клиента — выбор профиля мимикрии прямо в боте
- Получить QR-код / текст / .conf файл по любому клиенту
- Удалить клиента с подтверждением
- Статус сервера (uptime AmneziaWG, количество подключений, нагрузка)

**Установка:**

```bash
# Скачать установщик из того же репо
sudo curl -fsSL https://raw.githubusercontent.com/pumbaX/awg-multi-script/main/tg-bot.sh -o /tmp/tg-bot.sh

# Запустить
sudo bash /tmp/tg-bot.sh
```

В процессе установщик спросит:
1. **Bot Token** — получи у [@BotFather](https://t.me/BotFather): `/newbot` → имя → токен
2. **Telegram ID** — твой ID для авторизации (узнать через [@userinfobot](https://t.me/userinfobot))

После установки бот стартует как systemd-сервис (`awg-bot.service`) и сам поднимается при перезагрузке.

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

---

## Подводные камни

> ⚠️ **Endpoint = IP, не домен.** Доменное имя в `Endpoint = ` вызывает дедлок переподключения на Keenetic и других роутерах.

> ⚠️ **MTU должен совпадать** между сервером и клиентом. По умолчанию 1380, для AWG 2.0 + CPS лучше 1320.

> ⚠️ **I-параметры должны совпадать** между сервером и клиентом. После пересоздания сервера обязательно переимпортируй конфиг на всех клиентах — иначе handshake висит без ошибок в dmesg.

> ⚠️ **AmneziaVPN < 4.8.12.7 не поддерживает AWG 2.0.** Обнови клиент до последней версии.

> ⚠️ **Параметры v5.2 и старше** могут иметь кривое распределение H1-H4. Работают, но для идеального `12/12` в анализаторе пересоздай сервер через v6.2.

> ⚠️ **LXC/OpenVZ контейнеры** — `sysctl net.ipv4.ip_forward=1` может требовать прав хоста. Скрипт пробует `/proc/sys/...` как fallback, но если не работает — включи IP forwarding на хосте виртуализации.

---

## Импорт на клиенте

[**AmneziaVPN**](https://amnezia.org) (Android / iOS / macOS / Windows / Linux):
- **QR** — пункт 3 → 4, сканируй с терминала
- **Текст** — пункт 3 → 5 для больших конфигов (QUIC Full) → копируй в буфер
- **Файл** — `Добавить туннель → Из файла` → передай `/root/<имя>_awg2.conf` через scp

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

**AWG Toolza v6.7** · MIT License

</div>
