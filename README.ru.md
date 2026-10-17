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
  <a href="#скриншоты">Скриншоты</a> ·
  <a href="docs/routing-rules.ru.md">Правила маршрутизации</a> ·
  <a href="#частые-вопросы">Вопросы</a> ·
  <a href="#сборка-из-исходников">Сборка</a>
</p>

<p align="center"><img src="docs/images/screenshots/server-browsing.gif" alt="Главное окно V2Mac: сортировка серверов по задержке, Избранное и поиск" width="760"></p>

Вставьте ссылку на подписку, выберите сервер — и получите локальный прокси SOCKS5 + HTTP, или включите режим TUN, чтобы через него шёл весь Mac. V2Mac — бесплатная **альтернатива v2rayN и V2RayX для macOS** с открытым исходным кодом, написанная нативно на SwiftUI с Liquid Glass. Без Electron, без аналитики и телеметрии.

## Установка

Нужна **macOS 26 или новее** на **Apple Silicon** (M1 и новее).

**Homebrew** (рекомендуется, без запроса Gatekeeper):

```sh
brew install --cask lordversa/tap/v2mac
```

Обновление: `brew upgrade --cask v2mac`.

**Вручную:**

1. Скачайте `V2Mac-<version>.dmg` из [последнего релиза](https://github.com/LordVersA/v2mac/releases/latest) и перетащите **V2Mac** в **Программы**.
2. Приложение не нотариально заверено, поэтому macOS блокирует первый запуск. Откройте его один раз, затем нажмите **Всё равно открыть** в **Системные настройки → Конфиденциальность и безопасность** или выполните:
   ```sh
   xattr -dr com.apple.quarantine /Applications/V2Mac.app
   ```

**Первое подключение:**

1. Нажмите **Добавить подписку** и вставьте ссылку (или ссылку `vless://`, `vmess://`, `trojan://`, `ss://`, `hy2://`).
2. Дважды щёлкните сервер, чтобы подключиться.
3. Укажите в приложениях `socks5://127.0.0.1:10808` или `http://127.0.0.1:10808`, либо включите **Системный прокси** или **TUN**.

Закрытие окна не останавливает прокси. Чтобы остановить, выйдите через ⌘Q.

## Возможности

### Протоколы и импорт

| | |
|---|---|
| **Протоколы** | VLESS (включая REALITY и XTLS Vision), VMess, Trojan, Shadowsocks, Hysteria2, WireGuard, SOCKS, HTTP и полные JSON-конфигурации Xray |
| **Подписки** | Автообновление, показ расхода трафика и даты окончания, если их передаёт провайдер |
| **Быстрый импорт** | Щелчок по ссылке где угодно, кнопка провайдера `v2mac://install-config?url=…`, вставка скриншота QR-кода, перетаскивание файлов конфигурации и QR-картинок на окно |
| **Редактор серверов** | Все параметры вручную: транспорт, TLS или REALITY, Mux. Правка импортированных серверов без изменения оригинала |
| **Избранное** | Отмечайте серверы звездой; обновление подписки не удалит их без вопроса |

### Подключение

- **Тесты задержки:** real-delay и TCP ping для всей группы сразу, с сортировкой по скорости и замером скорости загрузки.
- **Автовыбор сервера** (по желанию): выбирает рабочий сервер по реальной HTTP-задержке, следит за ним и переключается по порядку группы, если он завис или стал медленным.
- **Режим TUN:** один переключатель направляет через прокси все приложения и все DNS-запросы. Не нужен платный аккаунт разработчика или системное расширение; `Scripts/check-tun.sh` проверяет отсутствие утечек.
- **Системный прокси:** один переключатель направляет системный прокси macOS на V2Mac, а цветная точка показывает, кому он сейчас принадлежит.
- **Kill switch** (по желанию): пока вы подключены, блокирует всё, кроме сервера и локальной сети, даже при обрыве соединения; через брандмауэр macOS (pf).
- **Cloudflare WARP:** регистрация бесплатного устройства WARP (MASQUE), ключ WARP+, WARP как отдельный сервер или в цепочке за вашим сервером.
- **Надёжность:** перезапуск ядра после сбоя, сна или смены сети, переподключение при запуске.
- **Живое переключение:** другой сервер подставляется в работающее ядро без перезапуска.

### Маршрутизация

- **Режимы:** Глобальный, Только правила (Rules Only), Напрямую или **Обход** регионов (Иран, Китай, Россия), чтобы местные сайты шли напрямую.
- **Свои правила, как в Proxifier:** упорядоченные правила Прокси / Напрямую / Блок по сайтам и приложениям. Импорт профилей Proxifier `.ppx`, правил Clash, файлов hosts, списков Adblock, тегов geosite и geoip.
- **Конструктор правил:** выбор стран на карте мира и сервисов (Google, Telegram, OpenAI, Netflix, реклама…) из списка.
- **Окно соединений:** все соединения, сгруппированные по хосту или приложению, с правилом, которое их направило.

→ Полное руководство: **[Свои правила маршрутизации](docs/routing-rules.ru.md)**

### Интеграция с macOS

- **Управление из строки меню:** подключение, смена сервера, скорость отдачи и загрузки, выходной IP и страна.
- **Пункт управления, Быстрые команды, Spotlight и Siri:** подключение, отключение, переключение TUN, режима маршрутизации, системного прокси или kill switch.
- **Привилегированный помощник:** сборки с подписью Apple используют помощник `SMAppService`, который одобряется один раз; V2Mac никогда не видит и не хранит пароль администратора.
- **Резервная копия:** экспорт подписок, серверов, избранного и настроек в файл `.v2m` и восстановление на другом Mac.
- **А также:** общий доступ по LAN с паролем, QR-коды, просмотр логов, уведомления, запуск при входе и обновление приложения и ядра Xray в один щелчок.
- **Языки:** английский, персидский (справа налево), упрощённый китайский и русский.
- **Приватность:** без аналитики и телеметрии. Секреты хранятся в зашифрованном локальном файле или, по желанию, в Связке ключей.

## Скриншоты

На всех скриншотах — вымышленные демо-серверы.

<p align="center"><img src="docs/images/screenshots/main.png" alt="Главное окно V2Mac: группы подписок, задержка и скорость серверов, инспектор и панель подключения" width="760"></p>

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshots/add-subscription.png" alt="Окно добавления подписки" width="380"><br><sub>Добавление подписки</sub></td>
    <td align="center"><img src="docs/images/screenshots/server-editor.png" alt="Редактор сервера VLESS" width="380"><br><sub>Правка любого сервера</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshots/rule-builder-countries.png" alt="Карта мира в конструкторе правил с выбранными странами" width="380"><br><sub>Конструктор правил: страны на карте</sub></td>
    <td align="center"><img src="docs/images/screenshots/custom-rules.png" alt="Свои правила маршрутизации в настройках" width="380"><br><sub>Свои правила маршрутизации</sub></td>
  </tr>
</table>

<details>
<summary><b>Больше скриншотов</b></summary>

<p align="center"><img src="docs/images/screenshots/settings-tour.gif" alt="Анимированный обзор всех вкладок настроек V2Mac" width="560"></p>
<p align="center"><img src="docs/images/screenshots/connection-settings.png" alt="Настройки подключения: автовыбор сервера и поведение при сбое TUN" width="560"></p>
<p align="center"><img src="docs/images/screenshots/routing-settings.png" alt="Настройки маршрутизации с обходом Ирана" width="560"></p>
<p align="center"><img src="docs/images/screenshots/sharing.png" alt="QR-код сервера для передачи" width="328"></p>

</details>

## Защита от утечек в Chrome: noleaker

Один прокси не мешает браузеру выдать вас: WebRTC может раскрыть настоящий IP, DNS и QUIC могут обойти прокси, а часовой пояс и язык выдают местоположение. [**noleaker**](https://github.com/LordVersA/noleaker) — бесплатное расширение того же автора для Chrome и браузеров на Chromium, работающее в паре с V2Mac: направляет трафик и DNS через SOCKS5-прокси V2Mac, закрывает утечки WebRTC и QUIC, подстраивает часовой пояс, язык и геолокацию под страну сервера и блокирует запросы, если прокси упал.

Настройка: установите [последний релиз](https://github.com/LordVersA/noleaker/releases/latest), добавьте прокси `127.0.0.1:10808` и включите **Protection**. Имя пользователя и пароль прокси в V2Mac оставьте пустыми.

## Частые вопросы

<details>
<summary><b>V2Mac — это клиент V2Ray для Mac?</b></summary>

Да. V2Mac использует [Xray-core](https://github.com/XTLS/Xray-core), активно развиваемого преемника ядра V2Ray, поэтому читает ссылки и подписки V2Ray и Xray (VLESS, VMess, Trojan, Shadowsocks), а также Hysteria2 и WireGuard.
</details>

<details>
<summary><b>Поддерживаются VLESS REALITY и XTLS Vision?</b></summary>

Да, и в ссылках, и в редакторе серверов, вместе с транспортами TCP, WebSocket, gRPC, HTTPUpgrade, XHTTP (SplitHTTP) и mKCP.
</details>

<details>
<summary><b>Как пустить через прокси все приложения, даже без настроек прокси?</b></summary>

Включите **TUN** рядом с меню маршрутизации. Все приложения и DNS-запросы пойдут через сервер. Один раз одобрите помощник (сборки с подписью Apple) или вводите пароль администратора раз за сеанс (ad-hoc сборки).
</details>

<details>
<summary><b>Работает ли на Mac с Intel или на старой macOS?</b></summary>

Нет. Нужна macOS 26 или новее на Apple Silicon.
</details>

<details>
<summary><b>Почему macOS пишет, что приложение нельзя открыть?</b></summary>

DMG не нотариально заверен. Используйте **Всё равно открыть** в настройках безопасности, команду `xattr` выше или установку через Homebrew.
</details>

<details>
<summary><b>Собирает ли V2Mac данные?</b></summary>

Нет. Аналитики и телеметрии нет. Кроме вашего трафика, V2Mac обращается только к адресам ваших подписок, к GitHub за обновлениями и файлами правил и к публичному сервису IP для проверки выхода после подключения.
</details>

## Сборка из исходников

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

Нужны Xcode 26+ и [XcodeGen](https://github.com/yonaskolb/XcodeGen). Устройство приложения описано в [docs/SPEC.md](docs/SPEC.md). Тесты пакета: `cd Packages/V2MacCore && swift test`.

Сообщения об ошибках и pull request'ы — в [Issues](https://github.com/LordVersA/v2mac/issues).

## Лицензия

[GPL-3.0](LICENSE). Включает [Xray-core](https://github.com/XTLS/Xray-core) (MPL-2.0); см. [THIRD_PARTY.md](THIRD_PARTY.md).

<p align="center"><sub>Если V2Mac вам помогает, ⭐ поможет другим его найти.</sub></p>
