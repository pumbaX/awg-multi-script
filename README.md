<div align="center">

# **AWG Multi Script**

**Универсальный менеджер AmneziaWG** — разверни VPN на VPS одной командой.<br>Обфускация, мимикрия, DPI-обход. WireGuard → AWG 2.0.

<br>

[![License: MIT](https://img.shields.io/badge/License-MIT-ffffff?style=flat-square&labelColor=000000)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Ubuntu-22.04%20%2F%2024.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Protocol](https://img.shields.io/badge/AWG-1.0%20→%202.0-00d4ff?style=flat-square)](#протоколы)
[![Version](https://img.shields.io/badge/version-4.1-00ff88?style=flat-square)](#)
</div>

## Быстрый старт
```bash
curl -s https://raw.githubusercontent.com/pumbaX/awg-multi-script/main/awg.sh -o /tmp/awg.sh
sudo bash /tmp/awg.sh
```
## Что это

**AWG Multi Script** — интерактивный bash-менеджер для установки, настройки и управления AmneziaWG VPN-сервером. Один скрипт закрывает весь цикл: установка зависимостей, генерация сервера с мимикрией, управление клиентами, статистика трафика, бэкап, firewall.

Без ручного редактирования конфигов. Без знания протокола изнутри.

---

## Возможности

| | Возможность | Детали |
|---|---|---|
| 🔧 | **Единый интерфейс** | Установка, генерация, управление клиентами — всё в одном меню |
| 🔀 | **Все версии AWG** | WireGuard, AWG 1.0, AWG 1.5, AWG 2.0 на выбор |
| 🎭 | **Мимикрия трафика** | 5 профилей: QUIC, TLS 1.3, DTLS, SIP, ручной домен |
| 📦 | **I1 из реального пакета** | Свежий QUIC/TLS/DTLS-пакет через API для выбранного домена |
| 🔢 | **Автогенерация обфускации** | Jc, Jmin, Jmax, S1–S4, H1–H4 с корректными диапазонами |
| 👥 | **Управление клиентами** | Добавление, статистика (↑↓), QR-коды, очистка |
| 🔥 | **Firewall** | UFW + iptables NAT/FORWARD — автоматически |
| 💾 | **Бэкап** | Авто-бэкап конфига перед пересозданием сервера |
| 🌐 | **Проверка доменов** | Ping-тест пулов мимикрии с цветным выводом |
| 🛡️ | **Защита от зависаний** | Все сетевые вызовы обёрнуты в `timeout` |
| 🗑️ | **Полное удаление** | Пакеты, конфиги, правила firewall — одной командой |

---

## Протоколы

| Версия | Jc / Jmin / Jmax | S1 / S2 | S3 / S4 | H1–H4 | I1 |
|:---:|:---:|:---:|:---:|:---:|:---:|
| WireGuard | ✗ | ✗ | ✗ | ✗ | ✗ |
| AWG 1.0 | ✅ `Jc ≥ 4` | ✅ | ✗ | одиночные | ✗ |
| AWG 1.5 | ✅ | ✅ | ✗ | одиночные | ✅ только клиент |
| AWG 2.0 | ✅ | ✅ | ✅ | диапазоны | ✅ сервер + клиент |

> **I2–I5** в текущей версии не генерируются — I1 достаточно для большинства сценариев обхода DPI.

---

## Профили мимикрии

```
┌──────────────────────────────────────────────────────────┐
│  Выбери профиль имитации трафика                         │
│                                                          │
│  [1]  QUIC Initial     →  HTTP/3, CDN (лучший в 2026)    │
│  [2]  QUIC 0-RTT       →  Early Data, быстрый старт      │
│  [3]  TLS 1.3          →  HTTPS (макс. совместимость)    │
│  [4]  DTLS 1.3         →  WebRTC / STUN (видеозвонки)    │
│  [5]  SIP              →  VoIP (телефонные звонки)       │
│  [6]  Случайный домен  →  Из любого пула                 │
│  [7]  Ручной ввод      →  Свой домен через API           │
│  [8]  Без имитации     →  Только обфускация              │
└──────────────────────────────────────────────────────────┘
```

После выбора скрипт автоматически:
1. Выбирает случайный **доступный** домен из проверенного пула
2. Запрашивает свежий I1 через API (`junk.web2core.workers.dev`)
3. Встраивает в конфиг (только AWG 1.5 / 2.0)

<details>
<summary><b>🌐 Доменные пулы — 50+ проверенных хостов</b></summary>

<br>

**QUIC Initial (HTTP/3)**
```
yandex.net, yastatic.net, vk.com, mycdn.me, mail.ru, ozon.ru,
wildberries.ru, wbstatic.net, sber.ru, tbank.ru, gosuslugi.ru,
gcore.com, fastly.net, cloudfront.net, microsoft.com, icloud.com,
github.com, cdn.jsdelivr.net, wikipedia.org, dropbox.com,
steamstatic.com, spotify.com, akamaiedge.net, msedge.net, azureedge.net
```

**QUIC 0-RTT (Early Data)**
```
yandex.net, vk.com, mail.ru, ozon.ru, wildberries.ru, sber.ru,
tbank.ru, gosuslugi.ru, gcore.com, fastly.net, cloudfront.net,
microsoft.com, github.com, cdn.jsdelivr.net, wikipedia.org, spotify.com
```

**TLS 1.3 Client Hello (HTTPS)**
```
yandex.ru, vk.com, mail.ru, ozon.ru, wildberries.ru, sberbank.ru,
tbank.ru, gosuslugi.ru, kaspersky.ru, github.com, gitlab.com,
stackoverflow.com, microsoft.com, apple.com, amazon.com,
cloudflare.com, jetbrains.com, docker.com, ubuntu.com, debian.org
```

**DTLS 1.3 (WebRTC / STUN)**
```
stun.yandex.net, stun.vk.com, stun.mail.ru, stun.sber.ru,
stun.stunprotocol.org, stun.voipbuster.com, meet.jit.si,
stun.services.mozilla.com, stun.zoiper.com, stun.counterpath.com,
stun.sipgate.net, stun.ekiga.net, stun.ideasip.com
```

**SIP (VoIP)**
```
sip.beeline.ru, sip.mts.ru, sip.megafon.ru, sip.rostelecom.ru,
sip.yandex.ru, sip.vk.com, sip.mail.ru, sip.sipnet.ru,
sip.zadarma.com, sip.iptel.org, sip.linphone.org,
sip.antisip.com, sip.voipbuster.com, sip.3cx.com
```

</details>

---

## Меню

```
╔══════════════════════════════════════════════╗
║        AmneziaWG Manager v4.1                ║
║     С генератором мимикрии (QUIC/TLS/DTLS)   ║
╚══════════════════════════════════════════════╝
  IP сервера : 1.2.3.4
  Порт       : 34110
  Интерфейс  : активен
  Клиентов   : 3

  1) Установка зависимостей и AmneziaWG
  2) Создать сервер + первый клиент (с мимикрией)
  3) Добавить клиента
  4) Показать клиентов
  5) Показать QR клиента
  6) Перезапустить awg0
  7) Удалить всё
  8) Проверить домены из пулов (ping)
  9) Очистить всех клиентов (без удаления сервера)
  0) Выход
```

---

## Вывод — клиенты

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                         КЛИЕНТЫ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ┌─ [1] phone
  │  IP:        10.102.0.2/32
  │  Трафик:    ↑ 14.76 МБ  ↓ 342.89 МБ
  │  Статус:    ● активен
  │  Endpoint:  5.6.7.8
  └──────────────────────────────────────────────────────

  ┌─ [2] laptop
  │  IP:        10.102.0.3/32
  │  Трафик:    ↑ 0 КБ  ↓ 0 КБ
  │  Статус:    ○ офлайн (15 мин)
  │  Endpoint:  —
  └──────────────────────────────────────────────────────

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ↑ выгрузка (от клиента)   ↓ загрузка (к клиенту)
  Офлайн: handshake не обновлялся > 2 мин
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Вывод — проверка доменов

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
              Проверка доступности доменов
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  QUIC Initial (HTTP/3):
    ✓  yandex.net
    ✓  yastatic.net
    ✓  vk.com
    ✗  wildberries.ru
    ✓  sber.ru
    ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ Доступно: 21 из 27 доменов
  ⚠ Недоступные — автоматически исключены из выбора
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Требования

| Параметр | Значение |
|---|---|
| ОС | Ubuntu 22.04 / 24.04 |
| Виртуализация | KVM (не OpenVZ / LXC) |
| Сеть | Публичный IPv4 |
| Права | root |

---

## Файлы

| Путь | Назначение |
|---|---|
| `/etc/amnezia/amneziawg/awg0.conf` | Серверный конфиг |
| `/root/client1_awg2.conf` | Первый клиент |
| `/root/<name>_awg2.conf` | Дополнительные клиенты |
| `/var/log/awg-manager.log` | Лог операций |

---

## Импорт на клиенте

Используй **[AmneziaVPN](https://amnezia.org)**:

- **QR-код** — пункт меню `5`, сканируй из терминала
- **Файл** — «Добавить туннель → Из файла» → `/root/<name>.conf`

---

<div align="center">

## Благодарности

Скрипт вдохновлён проектом **[AmneziaWG Architect](https://architect.vai-rice.space/)** —<br>
веб-генератором продвинутой обфускации для обхода DPI.<br>
Профили мимикрии и подход к I1–I5 основаны на его архитектуре.

<br>

---

**AWG Multi Script v4.1** · MIT License

*Разработано для сообщества [AWG-Manager](https://t.me/awgmanager)*

</div>
