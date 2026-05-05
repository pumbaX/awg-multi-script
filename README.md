<div align="center">

# **AWG Toolza**

**Менеджер AmneziaWG 2.0** — VPN с DPI-обходом одной командой.<br>
3 уровня обфускации, 5 профилей мимикрии, локальный CPS-генератор, **Warp туннель Cloudflare**, DPI-тест.

<br>

[![License: MIT](https://img.shields.io/badge/License-MIT-ffffff?style=flat-square&labelColor=000000)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Ubuntu%2024%20%2F%20Debian%2012%2B-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Protocol](https://img.shields.io/badge/AWG-2.0%20only-00d4ff?style=flat-square)](#)
[![Version](https://img.shields.io/badge/version-6.7.4-ff6b00?style=flat-square)](#)

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

**Меню Warp (пункт 15):**

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
- 🥇 **Cloudflare Zero Trust** на dash.cloudflare.com — безлимит до 50 устройств
- 🥈 Приложение **1.1.1.1** → Аккаунт → Ключ
- 🥉 Реферальная программа в 1.1.1.1 (до 25 ГБ, может уже не работать)

**Если Warp не подключается на РФ хостинге:**
1. `15 → 8` — импорт готового профиля через Google Cloud Shell
2. `15 → 9` — автоматический поиск рабочего endpoint
3. Если ничего не помогло — провайдер режет UDP к Cloudflare, нужен другой хостинг


## Меню

```
╔══════════════════════════════════════════════╗
║    AWG Toolza v6.7.4                         ║
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

**AWG Toolza v6.7.4** · MIT License

</div>
