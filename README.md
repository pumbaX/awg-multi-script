<div align="center">

# **Awg2-Toolza**

**Менеджер AmneziaWG 2.0** — разверни VPN на VPS одной командой.<br>
Мимикрия под 10 протоколов, локальная генерация I1, бекап, DPI-обход.

<br>

[![License: MIT](https://img.shields.io/badge/License-MIT-ffffff?style=flat-square&labelColor=000000)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Ubuntu-22.04%20%2F%2024.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Protocol](https://img.shields.io/badge/AWG-2.0%20only-00d4ff?style=flat-square)](#протокол)
[![Version](https://img.shields.io/badge/version-5.0-00ff88?style=flat-square)](#)

</div>

---

## Быстрый старт

```bash
sudo curl -fsSL https://raw.githubusercontent.com/pumbaX/awg-multi-script/main/awg2.sh -o /usr/local/bin/awg2 && sudo chmod +x /usr/local/bin/awg2 && sudo awg2
```

# Запуск в любой момент
```bash
sudo awg2
```
---

**На кофе:**
Адрес USDT TRC20:
TN2rQAsGNHQr8wnneKRD14UMX629D2Ca5q

Адрес USDT ERC20:
0x721845234eeC44e0a9BaE78402965828C1bc6c57

Адрес USDT TON:
UQCwj-RY2a4BH7sIDDeLb77XRaPDq0mb1FVwyC4UaOGbLMYy

Адрес TON:
UQCdQtJO4CF0Lyeb93X2zdeWeAcDJ-ieBC3AaL7LIqWfMBg3

## Что это

**awg2-toolza** — интерактивный bash-менеджер для развёртывания и управления AmneziaWG 2.0 VPN-сервером. Один скрипт закрывает весь цикл: установка, генерация сервера с мимикрией, управление клиентами, статистика трафика, бекап и восстановление, firewall.

Версия 5.0 работает **только с AWG 2.0** — максимальный набор параметров обфускации, поддержка I1, диапазонные H1–H4.

---

## Возможности

| | Возможность | Детали |
|---|---|---|
| 🔧 | **Единый интерфейс** | 11 пунктов меню — установка, сервер, клиенты, бекап |
| 🎭 | **Мимикрия трафика** | 10 типов I1: QUIC, TLS, DTLS, HTTP/3, SIP, DNS, Noise_IK и др. |
| 🧬 | **Локальная генерация I1** | Пакеты собираются байт-в-байт на Python — без внешнего API |
| 📡 | **API как fallback** | Опционально: получить I1 с `junk.web2core.workers.dev` |
| 🔢 | **Автогенерация параметров** | Jc, Jmin, Jmax, S1–S4, непересекающиеся H1–H4 диапазоны |
| 👥 | **Управление клиентами** | Добавление, статистика (↑↓), QR-коды, очистка |
| 💾 | **Бекап / восстановление** | Полный бекап в `~/awg_backup/` с выбором точки восстановления |
| 🔥 | **Firewall** | UFW + iptables NAT/FORWARD — автоматически |
| 🌐 | **Проверка доменов** | Ping-тест пулов мимикрии с цветным выводом |
| 🛡️ | **Защита от падений** | `set -euo pipefail`, все сетевые вызовы в `timeout` |
| 🗑️ | **Полное удаление** | Пакеты, конфиги, правила firewall — одной командой |

---

## Протокол

Скрипт работает **только с AWG 2.0**. Это максимальная версия протокола:

| Параметр | AWG 2.0 |
|---|---|
| Jc / Jmin / Jmax | ✅ |
| S1 / S2 | ✅ |
| S3 / S4 | ✅ |
| H1–H4 | ✅ диапазоны (непересекающиеся по квадрантам) |
| I1 | ✅ сервер + клиент |

---

## Генерация I1

При ручном вводе домена (профиль **7**) доступен выбор типа пакета для мимикрии:

```
┌──────────────────────────────────────────────────────────────┐
│        Выбор типа I1                                                    │
│                                                                         │
│   1   QUIC Initial (RFC 9000)      — HTTP/3, лучший в 2026              │
│   2   QUIC 0-RTT (Early Data)      — быстрый старт                      │
│   3   TLS 1.3 Client Hello         — HTTPS, макс. совм.                 │
│   4   Noise_IK (Standard)          — нативный AWG handshake             │
│   5   DTLS 1.3 Handshake           — WebRTC / STUN                      │
│   6   HTTP/3 Host Mimicry          — QPACK заголовки                    │
│   7   SIP (VoIP Signaling)         — SIP REGISTER пакет                 │
│   8   TLS → QUIC (Alt-Svc)        — TLS ClientHello + ALPN h3          |
│   9   QUIC Burst (Multi-packet)    — тройной QUIC Initial               │
│  10   DNS Query (UDP 53)           — стандартный A-запрос               │
│  11   Запросить через API          — junk.web2core.workers.dev          │
└──────────────────────────────────────────────────────────────┘
```

Каждый тип генерирует корректный байт-уровневый пакет на Python:
- **TLS 1.3** — полный Record → Handshake → ClientHello → SNI Extension
- **QUIC** — Long Header RFC 9000 с реальным DCID/SCID
- **Noise_IK** — 148 байт: `type(4) + sender(4) + ephemeral(32) + enc_static(48) + enc_ts(28) + mac1(16) + mac2(16)`
- **DNS** — wire format с корректным label encoding
- **SIP** — валидный REGISTER запрос с branch/Call-ID

> I1 в формате `<b 0x...>` — единственный корректный формат для AWG 2.0. Теги `<c>`, `<t>`, `<r>` не используются (вызывают ErrorCode 1000 в старых клиентах).

---

## Профили мимикрии

```
┌──────────────────────────────────────────────────────────┐
│  Профили мимикрии (быстрый выбор из пулов)                          │
│                                                                     │
│  1   QUIC Initial      — HTTP/3, CDN (лучший в 2026)                │
│  2   QUIC 0-RTT        — Early Data, быстрый старт                  │
│  3   TLS 1.3           — HTTPS (макс. совместимость)                │
│  4   DTLS 1.3          — WebRTC / STUN (видеозвонки)                │
│  5   SIP               — VoIP (телефонные звонки)                   │
│  6   Случайный домен   — Из любого пула                             │
│  7   Ручной ввод       — Свой домен + выбор типа I1                 │
│  8   Без имитации      — Только обфускация                          │
└──────────────────────────────────────────────────────────┘
```

Для профилей 1–6: скрипт выбирает случайный домен из пула и запрашивает I1 через API.  
Для профиля 7: ручной домен + локальная генерация I1 любого из 10 типов.

<details>
<summary><b>🌐 Доменные пулы — 50+ хостов</b></summary>

<br>

**QUIC Initial (HTTP/3)**
```
yandex.net, yastatic.net, vk.com, mycdn.me, mail.ru, ozon.ru,
wildberries.ru, wbstatic.net, sber.ru, tbank.ru, gosuslugi.ru,
gcore.com, fastly.net, cloudfront.net, microsoft.com, icloud.com,
github.com, cdn.jsdelivr.net, wikipedia.org, dropbox.com,
steamstatic.com, spotify.com, akamaiedge.net, msedge.net, azureedge.net
```

**QUIC 0-RTT**
```
yandex.net, vk.com, mail.ru, ozon.ru, wildberries.ru, sber.ru,
tbank.ru, gosuslugi.ru, gcore.com, fastly.net, cloudfront.net,
microsoft.com, github.com, cdn.jsdelivr.net, wikipedia.org, spotify.com
```

**TLS 1.3 Client Hello**
```
yandex.ru, vk.com, mail.ru, ozon.ru, wildberries.ru, sberbank.ru,
tbank.ru, gosuslugi.ru, kaspersky.ru, github.com, gitlab.com,
stackoverflow.com, microsoft.com, apple.com, amazon.com,
cloudflare.com, google.com
```

**DTLS 1.3 (WebRTC / STUN)**
```
stun.yandex.net, stun.vk.com, stun.mail.ru, stun.sber.ru,
stun.stunprotocol.org, meet.jit.si, stun.services.mozilla.com
```

**SIP (VoIP)**
```
sip.beeline.ru, sip.mts.ru, sip.megafon.ru, sip.rostelecom.ru,
sip.yandex.ru, sip.vk.com, sip.mail.ru, sip.sipnet.ru,
sip.zadarma.com, sip.iptel.org, sip.linphone.org
```

</details>

---

## Меню

```
╔══════════════════════════════════════════════╗
║        AmneziaWG Manager v5.0                        ║
║     AWG 2.0 only — QUIC/TLS/DTLS/SIP/DNS             ║
╚══════════════════════════════════════════════╝
  IP сервера : 1.2.3.4
  Порт       : 47300
  Интерфейс  : активен
  Клиентов   : 2

  1)  Установка зависимостей и AmneziaWG
  2)  Создать сервер + первый клиент (с мимикрией)
  3)  Добавить клиента
  4)  Показать клиентов
  5)  Показать QR клиента
  6)  Перезапустить awg0
  7)  Удалить всё
  8)  Проверить домены из пулов (ping)
  9)  Очистить всех клиентов (без удаления сервера)
  10) Создать бекап (~/awg_backup/)
  11) Восстановить из бекапа
  0)  Выход
```

---

## Бекап и восстановление

**Пункт 10** — создаёт папку `~/awg_backup/awg2_backup_YYYYMMDD_HHMMSS/` и сохраняет:

| Файл | Содержимое |
|---|---|
| `awg0.conf` | Серверный конфиг |
| `*_awg2.conf` | Все клиентские конфиги |
| `awg_show_dump.txt` | Live-дамп `awg show awg0` |
| `awg-manager.log` | Лог операций |
| `backup_meta.txt` | Метаданные (timestamp, hostname) |

**Пункт 11** — показывает список бекапов с датой и количеством файлов, восстанавливает выбранный. Перед заменой текущий конфиг сохраняется как `.pre_restore`.

---

## Статус клиентов

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ┌─ [1] phone
  │  IP:        10.102.0.2/32
  │  Трафик:    ↑ 14.76 МБ  ↓ 342.89 МБ
  │  Статус:    ● активен
  │  Endpoint:  5.6.7.8
  └─────────────────────────────────────────────────────

  ┌─ [2] laptop
  │  IP:        10.102.0.3/32
  │  Трафик:    ↑ 0 КБ  ↓ 0 КБ
  │  Статус:    ○ офлайн (15 мин)
  └─────────────────────────────────────────────────────

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ↑ выгрузка (от клиента)   ↓ загрузка (к клиенту)
```

| Иконка | Статус |
|---|---|
| `●` зелёный | handshake < 2 мин назад |
| `◐` жёлтый | 2–5 мин без активности |
| `○` красный | > 5 мин / нет handshake |

---

## Требования

| Параметр | Значение |
|---|---|
| ОС | Ubuntu 22.04 / 24.04 |
| Виртуализация | KVM (не OpenVZ / LXC) |
| Сеть | Публичный IPv4 |
| Права | root |
| Python | 3.x (для генерации I1 и параметров) |

---

## Файлы

| Путь | Назначение |
|---|---|
| `/etc/amnezia/amneziawg/awg0.conf` | Серверный конфиг |
| `/root/client1_awg2.conf` | Первый клиент |
| `/root/<name>_awg2.conf` | Дополнительные клиенты |
| `/var/log/awg-manager.log` | Лог операций |
| `~/awg_backup/` | Директория бекапов |

---

## Импорт на клиенте

Используй **[AmneziaVPN](https://amnezia.org)**:

- **QR-код** — пункт меню `5`, сканируй прямо из терминала
- **Файл** — «Добавить туннель → Из файла» → передай `/root/<name>_awg2.conf`

> ⚠️ Endpoint в конфиге всегда указывается как IP-адрес, не домен — домен вызывает дедлок переподключения на Keenetic и других клиентах.

---

<div align="center">

## Благодарности

Вдохновлено проектом **[AmneziaWG Architect](https://architect.vai-rice.space/)** —<br>
веб-генератором продвинутой обфускации для обхода DPI.

<br>

---
*Разработано для сообщества [AWG-Manager](https://t.me/awgmanager)*

**awg2-toolza** · MIT License · 

</div>
