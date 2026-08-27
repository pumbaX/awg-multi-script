<div align="center">

# **AWG Toolza**

**Менеджер AmneziaWG 2.0 / 3.0 / 3.1** — одной командой.<br>
3 уровня обфускации, 9 профилей мимикрии (QUIC / cURL QUIC+ECH / DNS / STUN / WebRTC / SIP / NTP / RTP / SSDP), локальный CPS-генератор на базе payloadGen, **Warp туннель Cloudflare**, DPI-тест.

<br>

[![License: MIT](https://img.shields.io/badge/License-MIT-ffffff?style=flat-square&labelColor=000000)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Ubuntu%2024%20%2F%20Debian%2012%2B-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Protocol](https://img.shields.io/badge/AWG-2.0%20%2F%203.0%20%2F%203.1-00d4ff?style=flat-square)](#)
[![Version](https://img.shields.io/badge/version-v0.7.27-ff6b00?style=flat-square)](#)

<br>

[![Boosty](https://img.shields.io/badge/Boosty-Поддержать-F15F2C?style=for-the-badge&logo=boost&logoColor=white)](https://boosty.to/awgtoolza/donate)
[![YooMoney](https://img.shields.io/badge/YooMoney-Поддержать-8B3FFC?style=for-the-badge&logo=yandex&logoColor=white)](https://yoomoney.ru/to/4100119521619579)

</div>

---

## Быстрый старт

```bash
sudo curl -fsSL https://raw.githubusercontent.com/genaRijoff/awg-multi-script/main/awg2.sh -o /usr/local/bin/awg2 && sudo chmod +x /usr/local/bin/awg2 && sudo awg2
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

**AWG Toolza v0.7.27** · MIT License

</div>
