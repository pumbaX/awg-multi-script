<div align="center">

# **AmneziaWG Toolza**

**Менеджер AmneziaWG 2.0** — VPN с DPI-обходом одной командой.<br>
3 уровня обфускации, 5 профилей мимикрии, локальный CPS-генератор.

<br>

[![License: MIT](https://img.shields.io/badge/License-MIT-ffffff?style=flat-square&labelColor=000000)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Ubuntu%2024%20%2F%20Debian%2012%2B-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Protocol](https://img.shields.io/badge/AWG-2.0%20only-00d4ff?style=flat-square)](#)
[![Version](https://img.shields.io/badge/version-5.1-00ff88?style=flat-square)](#)

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

## Что нового в 5.2

- ✅ **3 уровня обфускации** — базовый / +I1 / полный CPS chain
- ✅ **Исправлен CPS-генератор** — все I-пакеты валидны (раньше Keenetic/Android вешались на handshake)
- ✅ **Debian 12/13** — сборка amneziawg-tools из git, не только Ubuntu
- ✅ **Случайная подсеть** `10.[10-55].[1-254].0/24` по умолчанию
- ✅ **DPI-тест** (пункт 12) — захват CPS пакета и анализ через Wireshark dissector
- ✅ **MTU override** для каждого клиента отдельно

---

## Требования

| Параметр | Значение |
|---|---|
| ОС | Ubuntu 24.04 / 24.10 / 25.04 / 25.10 или Debian 12 / 13 |
| Виртуализация | KVM (не OpenVZ / LXC) |
| Сеть | Публичный IPv4 |
| Права | root |
| Python | 3.x |

---

## Уровни обфускации

При создании сервера (пункт 2) скрипт спрашивает уровень:

| Уровень | Параметры | Совместимость | DPI стойкость |
|---|---|---|---|
| **1. Базовый** | H ranges + S1-S4 + Jc junk | ✅ все клиенты | Высокая |
| **2. +I1** | + один сигнатурный пакет (TLS/QUIC/DTLS/SIP/DNS) | ✅ современные | Очень высокая |
| **3. Полный CPS** | + I2-I5 энтропийные пакеты | ⚠️ может ломать старые клиенты | Максимум |

**По умолчанию — уровень 1.** Этого хватает в 95% случаев включая ТСПУ в РФ. Поднимай выше только если базовый блокируется.

---

## Профили мимикрии (для уровней 2 и 3)

```
1) TLS 1.3 Client Hello   — HTTPS (рекомендуется)
2) DTLS 1.3 (WebRTC)      — видеозвонки
3) SIP (VoIP)             — телефония
4) QUIC / HTTP/3          — Chrome-like Initial
5) Случайный профиль      — из любого пула с доменами
6) Ручной ввод домена     — свой домен + выбор типа CPS
```

CPS-генератор собирает байт-валидные пакеты на Python:
- **TLS 1.3** — Record → Handshake → ClientHello → SNI → ALPN → GREASE → X25519MLKEM768
- **QUIC v1/v2** — Long Header RFC 9000/9369 с реальным DCID/SCID/Token
- **DTLS** — record + ClientHello fragment
- **SIP** — REGISTER с branch / Call-ID / Via
- **DNS** — wire-format query

> Все I-пакеты начинаются с тега `<b 0x...>` — критическое требование парсера amneziawg-go.
> `<r>` режется на куски ≤999 байт для совместимости со старыми клиентами.

---

## Доменные пулы

| Профиль | Регион | Хосты |
|---|---|---|
| TLS | РФ | yandex.ru, vk.com, mail.ru, ozon.ru, sber.ru, gosuslugi.ru |
| TLS | Мир | github.com, microsoft.com, cloudflare.com, apple.com |
| QUIC | РФ | yastatic.net, mycdn.me, vk.com, mail.ru |
| QUIC | Мир | google.com, youtube.com, cloudflare-quic.com, fastly.net |
| DTLS | — | stun.yandex.net, stun.vk.com, stun.l.google.com, meet.jit.si |
| SIP | — | sip.beeline.ru, sip.mts.ru, sip.megafon.ru, sip.linphone.org |

При создании сервера выбирается **регион** (РФ / Мир) — фильтрует пулы.

---

## Меню

```
╔══════════════════════════════════════════════╗
║        AmneziaWG Toolza v5.2                 ║
║   AWG 2.0 only — TLS/DTLS/SIP/DNS/QUIC       ║
╚══════════════════════════════════════════════╝
  IP сервера : 11.22.30.94
  Порт       : 41300
  Интерфейс  : ● активен
  Клиентов   : 2

  1)  Установка зависимостей и AmneziaWG
  2)  Создать сервер + первый клиент
  3)  Добавить клиента
  4)  Показать клиентов
  5)  Показать QR клиента
  6)  Перезапустить awg0
  7)  Удалить всё
  8)  Проверить домены из пулов (ping)
  9)  Очистить всех клиентов
  10) Создать бекап (~/awg_backup/)
  11) Восстановить из бекапа
  12) DPI тест (захват и анализ CPS пакета)
  0)  Выход
```

---

## DPI тест (пункт 12)

Захватывает первый большой UDP-пакет от выбранного клиента и парсит его через встроенный pcap-анализатор. Распознаёт:

| Профиль | Маркеры | Verdict |
|---|---|---|
| **TLS** | Record `0x16 0301`, Handshake type `01` | √ TLS мимикрия работает |
| **QUIC v1/v2** | Long header, fixed bit, version, DCID/SCID, Token, Length varint | √ QUIC мимикрия работает |
| **DTLS** | Record `0x16 fefd/feff`, ClientHello | √ DTLS мимикрия работает |
| **SIP** | 14 методов: INVITE, REGISTER, OPTIONS, MESSAGE, NOTIFY... | √ SIP мимикрия работает |
| **DNS** | QR=0, qdcount, label encoding | √ DNS мимикрия работает |

Показывает выбранного клиента **по имени файла + VPN IP**, а не голый endpoint:
```
Подключённых клиентов: 2
1) phone_1i_awg2     10.45.12.2     33.224.32.48:2329
2) laptop_awg2       10.45.12.3     66.22.75.22:22702
```

---

## Параметры обфускации (AWG 2.0)

| Параметр | Описание |
|---|---|
| **Jc / Jmin / Jmax** | Junk-train: количество и размер мусорных пакетов перед handshake |
| **S1 / S2** | Padding для Init / Response пакетов |
| **S3 / S4** | Padding для Cookie / Data пакетов (новое в 2.0) |
| **H1-H4** | Диапазоны magic numbers (новое в 2.0) — каждый peer уникален |
| **I1-I5** | Custom Protocol Signature пакеты — мимикрия под TLS/QUIC/DTLS/SIP/DNS |

H1-H4 генерируются как **непересекающиеся диапазоны** по 4 квадрантам uint32 — гарантированно валидны для AWG 2.0.

---

## Бекап и восстановление

**Пункт 10** — папка `~/awg_backup/awg2_backup_YYYYMMDD_HHMMSS/`:

| Файл | Содержимое |
|---|---|
| `awg0.conf` | Серверный конфиг |
| `*_awg2.conf` | Все клиентские конфиги |
| `awg_show_dump.txt` | Live дамп `awg show awg0` |
| `awg-Toolza.log` | Лог операций |
| `backup_meta.txt` | Метаданные |

**Пункт 11** — список бекапов с датой и количеством файлов, `.pre_restore` бекапит текущее перед заменой.

---

## Статус клиентов (пункт 4)

```
  ┌─ [1] phone
  │  IP:        10.102.0.2/32
  │  Трафик:    ↑ 14.76 МБ  ↓ 342.89 МБ
  │  Статус:    ● активен
  │  Endpoint:  15.6.17.18
  └─────────────────────────────────────────

  ┌─ [2] laptop
  │  IP:        10.102.0.3/32
  │  Трафик:    ↑ 0 КБ  ↓ 0 КБ
  │  Статус:    ○ офлайн (15 мин)
  └─────────────────────────────────────────
```

| Иконка | Статус |
|---|---|
| `●` зелёный | handshake < 2 мин назад |
| `◐` жёлтый | 2–5 мин без активности |
| `○` красный | > 5 мин / нет handshake |

---

## Файлы

| Путь | Назначение |
|---|---|
| `/etc/amnezia/amneziawg/awg0.conf` | Серверный конфиг |
| `/root/<name>_awg2.conf` | Клиентские конфиги |
| `/var/log/awg-Toolza.log` | Лог |
| `~/awg_backup/` | Бекапы |

---

## Подводные камни

> ⚠️ **Endpoint = IP, не домен.** Доменное имя в `Endpoint = ` вызывает дедлок переподключения на Keenetic и других роутерах.

> ⚠️ **MTU должен совпадать** между сервером и клиентом. По умолчанию 1380, для AWG 2.0 + CPS лучше 1320.

> ⚠️ **I-параметры должны совпадать** между сервером и клиентом. После пересоздания сервера обязательно переимпортируй конфиг на всех клиентах — иначе handshake висит без ошибок в dmesg.

> ⚠️ **AmneziaVPN < 4.8.12.7 не поддерживает AWG 2.0.** Обнови клиент до последней версии.

---

## Импорт на клиенте

[**AmneziaVPN**](https://amnezia.org) (Android / iOS / macOS / Windows / Linux):
- **QR** — пункт меню `5`, сканируй с терминала
- **Файл** — `Добавить туннель → Из файла` → передай `/root/<name>_awg2.conf`

[**Keenetic**](https://docs.amnezia.org/documentation/instructions/keenetic-os-awg) — KeeneticOS 4.x+ или AWG Manager на Entware

---

## Поддержать

**Boosty:** https://boosty.to/awgtoolza/donate

| Сеть | Адрес |
|---|---|
| USDT TRC20 | `TN2rQAsGNHQr8wnneKRD14UMX629D2Ca5q` |
| USDT ERC20 | `0x721845234eeC44e0a9BaE78402965828C1bc6c57` |
| USDT TON | `UQCwj-RY2a4BH7sIDDeLb77XRaPDq0mb1FVwyC4UaOGbLMYy` |
| TON | `UQCdQtJO4CF0Lyeb93X2zdeWeAcDJ-ieBC3AaL7LIqWfMBg3` |

---

<div align="center">

Вдохновлено **[AmneziaWG Architect](https://architect.vai-rice.space/)** — веб-генератором обфускации.<br>
Спасибо **Vadim-Khristenko** за оригинальную идею.

*Отдельная благодарность [AWG-Manager](https://t.me/awgmanager)*
<br>

*Сообщество [AWG-Toolza](https://t.me/awgToolza)*

**AmneziaWG Toolza** · MIT License

</div>
