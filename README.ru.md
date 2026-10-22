<p align="center"><img src="docs/images/banner.jpg" alt="V2Mac — нативный клиент Xray-core для macOS с поддержкой VLESS, VMess, Trojan, Shadowsocks и Hysteria2" width="720"></p>

<h1 align="center">V2Mac</h1>

<p align="center"><b>Нативный клиент Xray-core и V2Ray для macOS.</b><br>
VLESS, REALITY, VMess, Trojan, Shadowsocks, Hysteria2 и WireGuard в быстром приложении для строки меню на SwiftUI для Apple Silicon.</p>

<p align="center">
  <a href="https://github.com/LordVersA/v2mac/releases/latest"><img src="https://img.shields.io/github/v/release/LordVersA/v2mac?label=release&color=0A84FF" alt="Последний релиз"></a>
  <a href="https://github.com/LordVersA/v2mac/releases"><img src="https://img.shields.io/github/downloads/LordVersA/v2mac/total?color=34C759" alt="Загрузки"></a>
  <a href="https://github.com/LordVersA/v2mac/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/LordVersA/v2mac/ci.yml?branch=main&label=CI" alt="Статус CI"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26 или новее">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-555555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/LordVersA/v2mac?color=blue" alt="Лицензия GPL-3.0"></a>
  <a href="https://github.com/LordVersA/v2mac/stargazers"><img src="https://img.shields.io/github/stars/LordVersA/v2mac?style=flat&color=FFCC00" alt="Звёзды на GitHub"></a>
</p>

<p align="center"><a href="README.md">English</a> | <a href="README.fa.md">فارسی</a> | <a href="README.zh.md">简体中文</a> | Русский</p>

<p align="center">
  <a href="#установка">Установка</a> ·
  <a href="#возможности">Возможности</a> ·
  <a href="https://github.com/LordVersA/v2mac/wiki/ru-Home"><b>Документация</b></a> ·
  <a href="#сборка-из-исходников">Сборка</a>
</p>

<p align="center"><img src="docs/images/screenshots/server-browsing.gif" alt="Главное окно V2Mac: сортировка серверов по задержке, избранное и поиск" width="760"></p>

Вставьте ссылку подписки, выберите сервер — и у вас локальный прокси SOCKS5 + HTTP; или включите режим TUN, чтобы через него шёл весь Mac. V2Mac — бесплатная **альтернатива v2rayN / V2RayX для macOS** с открытым кодом, написанная нативно на SwiftUI с Liquid Glass. Без Electron, без аналитики, без телеметрии.

## Установка

Нужна **macOS 26 или новее** на **Apple Silicon**.

```sh
brew install --cask lordversa/tap/v2mac
```

Или скачайте DMG из [последнего релиза](https://github.com/LordVersA/v2mac/releases/latest). Приложение не нотаризовано: при первом запуске нажмите **Всё равно открыть** в Системные настройки → Конфиденциальность и безопасность. Подробнее в [руководстве по установке](https://github.com/LordVersA/v2mac/wiki/ru-Installation).

**Быстрый старт:** нажмите **Add Subscription** и вставьте ссылку, дважды щёлкните сервер, затем используйте `127.0.0.1:10808` (SOCKS5 / HTTP) или включите **System Proxy** или **TUN**.

## Возможности

- **Протоколы:** VLESS (REALITY, XTLS Vision), VMess, Trojan, Shadowsocks, Hysteria2, WireGuard, SOCKS, HTTP и полные JSON-конфиги Xray.
- **Подписки:** автообновление, трафик и срок действия, избранное, импорт по QR и в один щелчок, полный редактор серверов.
- **Подключение:** тесты реальной задержки и скорости, автовыбор сервера, смена сервера без перезапуска, страна выхода в строке меню.
- **Весь Mac:** TUN, системный прокси и kill switch на основе pf.
- **Маршрутизация:** Global, Bypass regions (Иран, Китай, Россия), Rules Only и Direct, плюс правила Proxy / Direct / Block по сайтам и приложениям.
- **Замена Proxifier:** правила для приложений, импорт профилей `.ppx`, визуальный Rule Builder и живой список соединений.
- **Cloudflare WARP:** как отдельный сервер или в цепочке за вашим.
- **Безопасная песочница (бета):** приложения в мини-ВМ, у каждой свой сервер и без утечек при обрыве; каждое приложение — отдельное приложение Mac. Скачивается только при первом открытии.
- **macOS:** панель в строке меню, Команды, Siri, Spotlight, Пункт управления, виджет на рабочем столе, подсказки доменов Apple Intelligence, Touch ID, уведомления, резервное копирование. Английский, персидский, китайский и русский.

## Скриншоты

<p align="center"><img src="docs/images/screenshots/main.png" alt="Главное окно V2Mac: группы подписок, задержка и скорость серверов, инспектор и панель подключения" width="760"></p>

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshots/rule-editor-simple.png" alt="Редактор правил, простой вид" width="380"><br><sub>Правила для приложений и сайтов</sub></td>
    <td align="center"><img src="docs/images/screenshots/connections.png" alt="Окно Connections" width="380"><br><sub>Каждое соединение и его правило</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshots/rule-builder-countries.png" alt="Карта мира в Rule Builder" width="380"><br><sub>Rule Builder</sub></td>
    <td align="center"><img src="docs/images/screenshots/proxifier-import.png" alt="Импорт профиля Proxifier" width="380"><br><sub>Импорт из Proxifier</sub></td>
  </tr>
</table>

## Документация

**[Вики V2Mac](https://github.com/LordVersA/v2mac/wiki/ru-Home)** описывает всё подробно:

| | |
|---|---|
| [Установка](https://github.com/LordVersA/v2mac/wiki/ru-Installation) | Homebrew, DMG, первый запуск, обновления |
| [Серверы и подписки](https://github.com/LordVersA/v2mac/wiki/ru-Servers-and-Subscriptions) | Добавление, обновление, редактирование, тесты задержки |
| [Подключение](https://github.com/LordVersA/v2mac/wiki/ru-Connecting) | TUN, системный прокси, kill switch, проверка выхода, WARP |
| [Маршрутизация](https://github.com/LordVersA/v2mac/wiki/ru-Routing) | Режимы, свои правила, импорт из Proxifier, Rule Builder |
| [Соединения](https://github.com/LordVersA/v2mac/wiki/ru-Connections) | Живой список соединений и карта |
| [Безопасная песочница](https://github.com/LordVersA/v2mac/wiki/ru-Sandbox) | Мини-ВМ, приложения песочницы, выходы, магазин |
| [Строка меню и быстрые команды](https://github.com/LordVersA/v2mac/wiki/ru-Menu-Bar-and-Shortcuts) | Панель, клавиатура, Команды, уведомления |
| [Справочник настроек](https://github.com/LordVersA/v2mac/wiki/ru-Settings-Reference) | Все настройки, резервная копия, приватность |
| [Решение проблем и FAQ](https://github.com/LordVersA/v2mac/wiki/ru-Troubleshooting-and-FAQ) | Частые проблемы и вопросы |

Для защиты от утечек в Chrome используйте V2Mac вместе с [**noleaker**](https://github.com/LordVersA/noleaker), бесплатным расширением того же автора.

## Сборка из исходников

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

Нужны Xcode 26+ и [XcodeGen](https://github.com/yonaskolb/XcodeGen). Дизайн: [docs/SPEC.md](docs/SPEC.md). Тесты: `cd Packages/V2MacCore && swift test`. Сообщения об ошибках и pull request — в [Issues](https://github.com/LordVersA/v2mac/issues).

## Лицензия

[GPL-3.0](LICENSE). Включает [Xray-core](https://github.com/XTLS/Xray-core) (MPL-2.0); см. [THIRD_PARTY.md](THIRD_PARTY.md).

<p align="center"><sub>Если V2Mac вам помогает, ⭐ поможет другим его найти.</sub></p>
