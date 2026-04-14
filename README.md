<div align="center">

# **AWG Toolza**

**Менеджер AmneziaWG 2.0** — VPN с DPI-обходом одной командой.<br>
3 уровня обфускации, 5 профилей мимикрии, локальный CPS-генератор, DPI-тест.

<br>

[![License: MIT](https://img.shields.io/badge/License-MIT-ffffff?style=flat-square&labelColor=000000)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Ubuntu%2024%20%2F%20Debian%2012%2B-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Protocol](https://img.shields.io/badge/AWG-2.0%20only-00d4ff?style=flat-square)](#)
[![Version](https://img.shields.io/badge/version-5.5--fix-00ff88?style=flat-square)](#)

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

## Что нового в 5.5-fix

- 🔥 **I1-I5 убраны из серверного конфига** — CPS пакеты теперь только у клиента (как по спецификации AWG 2.0)
- 🔥 **Полностью переписан CPS-генератор** — порт [Special-Junk-Packet](https://github.com/Jeean1/Special-Junk-Packet-List): компактные реалистичные пакеты, все профили влезают в QR
- ✅ **Новый профиль Special Junk (по умолчанию)** — SIP REGISTER → TLS ClientHello → TLS ServerHello → CKE+CCS+Finished → HTTP/TLS. Проверен на ТСПУ РФ (домашний провайдер + мобильный инет)
- ✅ **Junker API интеграция** — опция для захвата реальных QUIC пакетов через [spatiumstas/junker](https://github.com/spatiumstas/junker), с автообрезкой жирных пакетов > 600 сим и fallback на синтетику
- ✅ **Убраны заблокированные домены** из пулов (cloudflare.com, youtube.com, facebook.com, discord.com, instagram.com, netflix.com) — заменены на реально доступные CDN
- ✅ **DPI тест переписан** — теперь понимает все типы пакетов (SIP/TLS/DTLS/DNS/QUIC/AWG data), не пугает ложными warnings, корректно показывает статус обфускации
- ✅ **QR-код** — проверка размера конфига перед генерацией (> 3000 байт → scp/cat вместо ошибки)
- ✅ **Компактные размеры I1-I5** — special ~2000 сим, quic ~1700, tls ~1300, sip ~1600, dns ~900. Все влезают в QR

### Из 5.4

- ✅ **Переработано главное меню** — логическая группировка: Основные / Утилиты / Бекапы / Опасная зона
- ✅ **Новый пункт 11** — «Сбросить сервер» — чистая переустановка без удаления пакетов
- ✅ **Бекап внутри сброса** — скрипт предлагает сохранить текущий конфиг перед сбросом
- ✅ **DPI тест поднят** с 12 в 7 — ближе к другим утилитам
- ✅ **QR перенесён** в sub-меню управления клиентами (пункт 3)
- ✅ **Opasная зона (10-12)** — упорядочена по степени разрушительности:
  - 10 → только клиенты
  - 11 → весь конфиг (пакеты остаются)
  - 12 → всё подчистую

### Из 5.3

- Управление клиентами (добавить/переименовать/удалить) в пункте 3
- Первый клиент называется `client1` по умолчанию
- H1-H4 строгие квадранты uint32 (исправлен баг генерации)
- Регион сервера сохраняется в конфиге
- 22 европейских SIP провайдера
- DPI-анализатор умеет пропускать junk пакеты

### Из 5.2

- 3 уровня обфускации (базовый / +I1 / полный I1-I5)
- Исправлен CPS-генератор (Keenetic/Android больше не виснут)
- Debian 12/13 через git+DKMS, Ubuntu 24+ через PPA
- Случайная подсеть `10.[10-55].[1-254].0/24` по умолчанию
- MTU override для каждого клиента

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

## Меню

```
╔══════════════════════════════════════════════╗
║    AWG Toolza v5.5-fix                                                                                          ║
║   AWG 2.0 only — Special Junk / QUIC / TLS / SIP                                           ║
╚══════════════════════════════════════════════╝
  IP сервера : 1.2.3.4
  Порт       : 47300
  Интерфейс  : ● активен
  Клиентов   : 2

  Основные:
  ◇  1)  Установка зависимостей и AmneziaWG
  ◇  2)  Создать сервер + первый клиент (с мимикрией)
  ◇  3)  Управление клиентами (добавить/rename/delete/QR)
  ◇  4)  Показать клиентов

  Утилиты:
  ◇  5)  Перезапустить awg0
  ◇  6)  Проверить домены из пулов (ping)
  ◇  7)  Тест DPI мимикрии (захват CPS пакета)

  Бекапы:
  ◆  8)  Создать бекап (~/awg_backup/)
  ◆  9)  Восстановить из бекапа

  Опасная зона:
  ◇ 10)  Очистить всех клиентов (без удаления сервера)
  ◇ 11)  Сбросить настройки сервера (чистая переустановка)
  ◇ 12)  Удалить всё (пакеты + конфиги)
     0)  Выход
```

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
1) ★ Special Junk (SIP+TLS flow) — рекомендуется
   SIP REGISTER → TLS ClientHello → ServerHello → CKE → HTTP
2) QUIC Initial (компактный ~400B)
3) TLS 1.3 (ClientHello + ServerHello + CKE)
4) SIP + TLS + DNS
5) DNS Query
6) Junker — реальный захват QUIC (нужен интернет)
```

CPS-генератор (порт Special-Junk-Packet) собирает байт-валидные пакеты на Python:
- **Special Junk** — полный TLS handshake flow: SIP REGISTER + ClientHello + ServerHello + ClientKeyExchange + ChangeCipherSpec + HTTP request. ~2000 символов, влезает в QR
- **QUIC** — компактный QUIC Initial 300-400B с точным Payload Length varint (Δ=0)
- **TLS** — ClientHello + ServerHello + CKE + HTTP/TLS Application Data
- **SIP** — REGISTER с branch / Call-ID / Via + TLS + DNS
- **DNS** — wire-format query с EDNS0 OPT
- **Junker** — реальные QUIC пакеты через [spatiumstas/junker](https://github.com/spatiumstas/junker) Cloudflare Worker API

> Все I-пакеты начинаются с тега `<b 0x...>` — критическое требование парсера amneziawg-go.
> `<r>` режется на куски ≤999 байт для совместимости со старыми клиентами.

---

## Параметры обфускации AWG 2.0

| Параметр | Описание |
|---|---|
| **Jc / Jmin / Jmax** | Junk-train: количество и размер мусорных пакетов перед handshake |
| **S1 / S2** | Padding для Init / Response пакетов (S2 ≤ 1188 — protocol limit) |
| **S3 / S4** | Padding для Cookie / Data пакетов (S4 ≤ 32 — AWG 2.0 лимит) |
| **H1-H4** | Magic numbers — диапазоны uint32 по 4 квадрантам (Q = 2^30) |
| **I1-I5** | CPS пакеты — мимикрия под TLS/QUIC/DTLS/SIP/DNS |

### H1-H4 квадранты

Каждый H строго в своём квадранте uint32:

```
H1 ∈ Q0 [5          .. 1073741823]
H2 ∈ Q1 [1073741824 .. 2147483646]
H3 ∈ Q2 [2147483647 .. 3221225469]
H4 ∈ Q3 [3221225470 .. 4294967292]
```

Ширина каждого диапазона — 30000-130000. Это гарантирует:
- Полное непересечение H
- Равномерное распределение по всему uint32
- Максимальная энтропия магических чисел

Проверить конфиг можно через **[AWG Analyzer](https://pumbax.github.io/awg-analyzer/)** — он покажет валидное ли распределение квадрантов (идеал = 12/12 баллов).

---

## Управление клиентами (пункт 3)

```
⚙  Управление клиентами
  1) Добавить клиента
  2) Переименовать клиента
  3) Удалить клиента
  4) Показать QR клиента
  0) Назад в главное меню
```

**Добавление** — генерит ключи, выделяет IP из подсети, предлагает профиль мимикрии (или наследует от сервера), записывает в серверный конфиг и создаёт `/root/<name>_awg2.conf`.

**Переименование** — показывает нумерованный список с именами и VPN IP, запрашивает новое имя, обновляет `# comment` в серверном конфиге через awk, переименовывает файл `/root/<old>_awg2.conf → <new>_awg2.conf`. Безымянные клиенты получают имя автоматически.

**Удаление** — список клиентов, подтверждение, удаление из runtime (`awg set awg0 peer <pk> remove`), вырезание блока `[Peer]` из конфига через awk, удаление файла клиента. Перед любым изменением — автоматический бекап `.pre_rename.<timestamp>` или `.pre_delete.<timestamp>`.

**QR-код** — вывод QR в терминал через qrencode, можно сразу сканировать с телефона.

---

## Сбросить сервер (пункт 11)

Чистая переустановка сервера **без удаления пакетов**. Идеально для пересоздания с новыми параметрами (например, обновить уровень обфускации или сменить регион) без полной переустановки.

**Workflow:**
```
1. Подтверждение: "Подтверди сброс [yes/N]"
2. Предложение бекапа: "Создать бекап перед сбросом? [Y/n]"
   → Y — сохраняет текущий конфиг в ~/awg_backup/
3. awg-quick down — останавливает интерфейс
4. Удаляет iptables правила NAT/FORWARD
5. Удаляет серверный конфиг + все .bak.*, .pre_rename.*, .pre_delete.*
6. Удаляет клиентские конфиги /root/*_awg2.conf
7. Удаляет UFW правила AmneziaWG
8. Сбрасывает SERVER_REGION к дефолту
```

**НЕ трогает:**
- Пакеты amneziawg / amneziawg-tools
- Kernel module
- Бинарники
- Лог `/var/log/awg-Toolza.log`
- Бекапы в `~/awg_backup/`

После сброса сразу можно пункт 2 — создать новый сервер с нуля. Если что-то пошло не так — пункт 9 (восстановить из бекапа) вернёт всё как было.

### Разница между пунктами 10, 11, 12

| Пункт | Что удаляет | Что оставляет | Когда использовать |
|---|---|---|---|
| **10. Очистить клиентов** | Все `[Peer]` блоки + файлы клиентов | Сервер работает, можно добавлять новых | Хочу стереть всех клиентов, но сервер оставить |
| **11. Сбросить сервер** | Весь конфиг + клиенты + firewall | Пакеты, бинарники, бекапы | Хочу пересоздать сервер с нуля без переустановки |
| **12. Удалить всё** | Всё выше + пакеты + PPA | Ничего | Хочу удалить AmneziaWG полностью |

---

## Регион сервера

При создании сервера выбирается регион — определяет какие доменные пулы использовать:

| Регион | Когда выбирать | Пулы |
|---|---|---|
| 🇷🇺 **РФ** | Сервер в РФ, клиенты в РФ | yandex.ru, vk.com, sber.ru, sip.beeline.ru... |
| 🌍 **Мир/Европа** | Сервер в EU, обход TSPU из РФ | github.com, sipgate.de, sip.ovh.net... |

Регион **сохраняется** в шапке серверного конфига (`# Region: ru/world`) и восстанавливается при следующем запуске скрипта. Пункт 6 (проверка доменов) покажет актуальный регион и проверит пулы именно под него.

### Доменные пулы

| Профиль | 🇷🇺 РФ | 🌍 Мир |
|---|---|---|
| **TLS** | yandex.ru, vk.com, mail.ru, ozon.ru, sber.ru, gosuslugi.ru | github.com, microsoft.com, cloudflare.com, apple.com |
| **QUIC** | yastatic.net, mycdn.me, ya.ru, dzen.ru | google.com, youtube.com, cloudflare-quic.com, fastly.net |
| **DTLS** | stun.yandex.net, stun.vk.com, stun.mail.ru | stun.l.google.com, meet.jit.si, stun.stunprotocol.org |
| **SIP** | sip.beeline.ru, sip.mts.ru, sip.megafon.ru, sip.tele2.ru | sipgate.de, sip.ovh.net, sip.voipfone.co.uk, sip.linphone.org |

**Европейские SIP провайдеры** (для `world`):
- 🇩🇪 sipgate.de, sip.dus.net, sip.easybell.de, sip.1und1.de, sip.t-online.de, sipcall.de
- 🇫🇷 sip.ovh.net, sip.free.fr, sip.numericable.fr
- 🇬🇧 sip.voipfone.co.uk, sip.voiptalk.org, sip.gradwell.com, sip.sipgate.co.uk
- 🇳🇱🇨🇭🇦🇹 sip.voipgate.com, sip.voys.nl, sip.peoplefone.ch, sip.fonira.com
- 🇮🇹🇪🇸 sip.messagenet.it, sip.eutelia.it, sip.fonyou.com
- 🇸🇪🇳🇴 sip.bahnhof.se, sip.com.no

---

## DPI тест (пункт 7)

Захватывает пакеты от выбранного клиента через tcpdump и анализирует. Распознаёт все типы:

| Тип | Что детектит |
|---|---|
| **SIP** | REGISTER, INVITE, OPTIONS, BYE, CANCEL, ACK |
| **TLS** | ClientHello, ServerHello, CKE, ChangeCipherSpec, Application Data (0x0301 и 0x0303) |
| **QUIC** | Long Header (Initial/0-RTT/Handshake) + Short Header (1-RTT) |
| **DTLS** | record + ClientHello |
| **DNS** | wire-format query |
| **AWG data** | обфусцированные пакеты с кастомными H-заголовками |

Три возможных результата:

```
✓ DPI тест пройден — CPS chain из 3 пакетов (sip, tls, tls-data)
✓ Обфускация работает (CPS уже прошли)
○ Ничего не поймали — попробуй переподключиться
```

Если CPS-пакеты уже пролетели до начала захвата — тест покажет «обфускация работает», а не ошибку.

---

## Бекап и восстановление

**Пункт 8** — папка `~/awg_backup/awg2_backup_YYYYMMDD_HHMMSS/`:

| Файл | Содержимое |
|---|---|
| `awg0.conf` | Серверный конфиг |
| `*_awg2.conf` | Все клиентские конфиги |
| `awg_show_dump.txt` | Live дамп `awg show awg0` |
| `awg-Toolza.log` | Лог операций |
| `backup_meta.txt` | Метаданные |

**Пункт 9** — список бекапов с датой и количеством файлов, `.pre_restore` бекапит текущее перед заменой.

Дополнительно:
- **Пункт 3** создаёт микро-бекапы при rename/delete (`.pre_rename.*` / `.pre_delete.*`)
- **Пункт 11** предлагает создать полноценный бекап перед сбросом

---

## Статус клиентов (пункт 4)

```
  ┌─ [1] client1
  │  » IP:       10.102.0.2/32
  │  ↑ Трафик:   ↑ 14.76 МБ  ↓ 342.89 МБ
  │  ∑ Статус:   ● активен
  │  » Endpoint: 15.61.71.11
  └─────────────────────────────────────────

  ┌─ [2] laptop
  │  » IP:       10.102.0.3/32
  │  ↑ Трафик:   ↑ 0 КБ  ↓ 0 КБ
  │  ∑ Статус:   ○ офлайн (15 мин)
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
| `/root/<n>_awg2.conf` | Клиентские конфиги |
| `/var/log/awg-Toolza.log` | Лог |
| `~/awg_backup/` | Бекапы |
| `/tmp/awg_domain_cache.txt` | Кэш проверки доменов (пункт 6) |

---

## Подводные камни

> ⚠️ **Endpoint = IP, не домен.** Доменное имя в `Endpoint = ` вызывает дедлок переподключения на Keenetic и других роутерах.

> ⚠️ **MTU должен совпадать** между сервером и клиентом. По умолчанию 1380, для AWG 2.0 + CPS лучше 1320.

> ⚠️ **I-параметры должны совпадать** между сервером и клиентом. После пересоздания сервера обязательно переимпортируй конфиг на всех клиентах — иначе handshake висит без ошибок в dmesg.

> ⚠️ **AmneziaVPN < 4.8.12.7 не поддерживает AWG 2.0.** Обнови клиент до последней версии.

> ⚠️ **Первый клиент в v5.3+** автоматически получает имя `client1`. При обновлении со старых версий существующие безымянные клиенты остаются такими — используй пункт 3 → 2 для переименования.

> ⚠️ **Старые H1-H4 из v5.2 и ниже** могут иметь кривое распределение по квадрантам. Работают, но для идеального `12/12` в анализаторе пересоздай сервер через v5.3+.

---

## Импорт на клиенте

[**AmneziaVPN**](https://amnezia.org) (Android / iOS / macOS / Windows / Linux):
- **QR** — пункт 3 → 4, сканируй с терминала
- **Файл** — `Добавить туннель → Из файла` → передай `/root/<n>_awg2.conf`

[**Keenetic**](https://docs.amnezia.org/documentation/instructions/keenetic-os-awg) — KeeneticOS 4.x+ или AWG Manager на Entware

---

## Проверка конфига

Проверить свой `.conf` на валидность, DPI-стойкость и оптимальность параметров можно через **[AWG Analyzer](https://pumbax.github.io/awg-analyzer/)** — полностью локальный JS-инструмент:

- Детект версии (WireGuard / AWG 1.0 / 1.5 / 2.0) + уровень обфускации
- Глубокий разбор I1-I5 (валидность `<b 0x...>`, лимит `<r>`, протокол)
- Проверка H1-H4 квадрантов (12/12 = идеал)
- Security / Stealth / DPI score
- Рекомендации CRIT/HIGH/MED/LOW + пошаговый upgrade path

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
Спасибо **Vadim-Khristenko** за оригинальную идею.<br>
CPS-генератор основан на **[Special-Junk-Packet](https://github.com/Jeean1/Special-Junk-Packet-List)** — проверенные пакеты для обхода DPI.<br>
Junker API — **[spatiumstas/junker](https://github.com/spatiumstas/junker)** — захват реальных QUIC пакетов.

*Отдельная благодарность [AWG-Manager](https://t.me/awgmanager)*

<br>

*Сообщество [AWG-Toolza](https://t.me/awgToolza)*

**AWGToolza v5.5-fix** · MIT License

</div>
