<p align="center"><img src="docs/images/banner.jpg" alt="V2Mac، کلاینت بومی Xray-core برای macOS با پشتیبانی از VLESS، VMess، Trojan، Shadowsocks و Hysteria2" width="720"></p>

<h1 align="center">V2Mac</h1>

<p align="center" dir="rtl"><b>کلاینت بومی macOS برای Xray-core و V2Ray.</b><br>
VLESS، REALITY، VMess، Trojan، Shadowsocks، Hysteria2 و WireGuard در یک برنامهٔ سریع منوبار با SwiftUI برای مک‌های Apple Silicon.</p>

<p align="center">
  <a href="https://github.com/LordVersA/v2mac/releases/latest"><img src="https://img.shields.io/github/v/release/LordVersA/v2mac?label=release&color=0A84FF" alt="آخرین نسخه"></a>
  <a href="https://github.com/LordVersA/v2mac/releases"><img src="https://img.shields.io/github/downloads/LordVersA/v2mac/total?color=34C759" alt="تعداد دانلود"></a>
  <a href="https://github.com/LordVersA/v2mac/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/LordVersA/v2mac/ci.yml?branch=main&label=CI" alt="وضعیت CI"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26 یا جدیدتر">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-555555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/LordVersA/v2mac?color=blue" alt="مجوز GPL-3.0"></a>
  <a href="https://github.com/LordVersA/v2mac/stargazers"><img src="https://img.shields.io/github/stars/LordVersA/v2mac?style=flat&color=FFCC00" alt="ستاره‌های گیت‌هاب"></a>
</p>

<p align="center"><a href="README.md">English</a> | فارسی | <a href="README.zh.md">简体中文</a> | <a href="README.ru.md">Русский</a></p>

<p align="center" dir="rtl">
  <a href="#نصب">نصب</a> ·
  <a href="#امکانات">امکانات</a> ·
  <a href="#تصاویر-برنامه">تصاویر</a> ·
  <a href="docs/routing-rules.fa.md">قوانین مسیریابی</a> ·
  <a href="#پرسش‌های-رایج">پرسش‌های رایج</a> ·
  <a href="#ساخت-از-سورس">ساخت</a>
</p>

<p align="center"><img src="docs/images/screenshots/server-browsing.gif" alt="پنجرهٔ اصلی V2Mac: مرتب‌سازی سرورها بر اساس تأخیر، باز کردن علاقه‌مندی‌ها و جستجو" width="760"></p>

<div dir="rtl">

لینک اشتراک را وارد کنید، یک سرور انتخاب کنید و یک پروکسی محلی SOCKS5 و HTTP تحویل بگیرید، یا حالت TUN را روشن کنید تا کل مک از آن عبور کند. V2Mac یک **جایگزین رایگان و متن‌باز v2rayN و V2RayX برای macOS** است که به‌صورت بومی با SwiftUI و Liquid Glass نوشته شده. بدون Electron، بدون آمارگیری و بدون ارسال داده.

## نصب

نیازمند **macOS 26 یا جدیدتر** روی **Apple Silicon** (M1 به بعد).

**Homebrew** (پیشنهادی، بدون هشدار Gatekeeper):

```sh
brew install --cask lordversa/tap/v2mac
```

برای به‌روزرسانی بعدی: `brew upgrade --cask v2mac`.

**دانلود دستی:**

1. فایل `V2Mac-<version>.dmg` را از [آخرین نسخه](https://github.com/LordVersA/v2mac/releases/latest) دانلود کنید و **V2Mac** را به **Applications** بکشید.
2. برنامه notarize نشده، پس macOS اولین اجرا را مسدود می‌کند. یک بار بازش کنید، سپس در **System Settings → Privacy & Security** روی **Open Anyway** بزنید، یا اجرا کنید:
   ```sh
   xattr -dr com.apple.quarantine /Applications/V2Mac.app
   ```

**اولین اتصال:**

1. روی **Add Subscription** بزنید و لینک خود را وارد کنید (یا یک لینک `vless://`، `vmess://`، `trojan://`، `ss://`، `hy2://`).
2. روی یک سرور دوبار کلیک کنید تا وصل شوید.
3. برنامه‌ها را روی `socks5://127.0.0.1:10808` یا `http://127.0.0.1:10808` تنظیم کنید، یا **System Proxy** یا **TUN** را روشن کنید.

بستن پنجره پروکسی را قطع نمی‌کند. برای توقف با ⌘Q خارج شوید.

## امکانات

### پروتکل‌ها و وارد کردن

| | |
|---|---|
| **پروتکل‌ها** | VLESS (همراه REALITY و XTLS Vision)، VMess، Trojan، Shadowsocks، Hysteria2، WireGuard، SOCKS، HTTP و کانفیگ‌های کامل JSON ایکس‌ری |
| **اشتراک‌ها** | به‌روزرسانی خودکار، با نمایش حجم مصرفی و تاریخ انقضا اگر سرویس‌دهنده بفرستد |
| **وارد کردن سریع** | کلیک روی لینک اشتراک‌گذاری در هر جا، دکمهٔ `v2mac://install-config?url=…` سرویس‌دهنده، چسباندن عکس QR، یا رها کردن فایل کانفیگ و تصویر QR روی پنجره |
| **ویرایشگر سرور** | همهٔ گزینه‌ها به‌صورت دستی: transport، TLS یا REALITY، Mux. ویرایش سرورهای واردشده بدون تغییر نسخهٔ اصلی |
| **علاقه‌مندی‌ها** | به سرورها ستاره بدهید؛ به‌روزرسانی اشتراک هرگز بدون پرسیدن حذفشان نمی‌کند |

### اتصال

- **تست تأخیر:** real-delay و TCP ping برای کل یک گروه، مرتب بر اساس سرعت، همراه سرعت دانلود.
- **انتخاب خودکار سرور** (اختیاری): بر اساس تأخیر واقعی HTTP یک سرور سالم انتخاب می‌کند، زیر نظرش دارد و اگر قطع یا کند شد به ترتیب گروه سراغ بعدی می‌رود.
- **حالت TUN:** با یک کلید همهٔ برنامه‌ها و همهٔ درخواست‌های DNS از پروکسی عبور می‌کنند. بدون نیاز به اکانت پولی توسعه‌دهنده یا system extension؛ `Scripts/check-tun.sh` نبودِ نشتی را بررسی می‌کند.
- **پروکسی سیستم:** یک کلید پروکسی سیستم macOS را روی V2Mac می‌گذارد، با یک نقطهٔ رنگی که نشان می‌دهد پروکسی دست کیست.
- **Kill switch** (اختیاری): در زمان اتصال همه‌چیز جز سرور و شبکهٔ محلی را مسدود می‌کند، حتی اگر اتصال قطع شود؛ با فایروال macOS (pf).
- **Cloudflare WARP:** ثبت دستگاه رایگان WARP (MASQUE)، استفاده از کلید WARP+، و افزودن WARP به‌عنوان سرور یا زنجیر کردنش پشت سرور خودتان.
- **پایدار:** پس از کرش، خواب یا تغییر شبکه هسته را دوباره راه می‌اندازد و هنگام اجرا دوباره وصل می‌شود.
- **تعویض زنده:** انتخاب سرور دیگر، آن را داخل هستهٔ در حال اجرا عوض می‌کند بدون ری‌استارت.

### مسیریابی

- **حالت‌ها:** Global، Rules Only، Direct، یا **Bypass** مناطق (ایران، چین، روسیه) تا سایت‌های داخلی مستقیم بروند.
- **قوانین سفارشی، مثل Proxifier:** قوانین مرتب Proxy / Direct / Block بر اساس سایت و برنامه. وارد کردن پروفایل‌های `.ppx` پروکسیفایر، قوانین Clash، فایل hosts، لیست‌های Adblock و تگ‌های geosite و geoip.
- **Rule Builder:** انتخاب کشورها روی نقشهٔ جهان و سرویس‌ها (Google، Telegram، OpenAI، Netflix، تبلیغات…) از یک لیست.
- **نمای Connections:** همهٔ اتصال‌ها، گروه‌بندی‌شده بر اساس میزبان یا برنامه، همراه قانونی که مسیرشان را تعیین کرده.

← راهنمای کامل: **[قوانین مسیریابی سفارشی](docs/routing-rules.fa.md)**

### یکپارچگی با macOS

- **کنترل از منوبار:** اتصال، تعویض سرور، سرعت زندهٔ آپلود و دانلود، IP و کشور خروجی.
- **Control Center، Shortcuts، Spotlight و Siri:** اتصال، قطع، و روشن و خاموش کردن TUN، حالت مسیریابی، پروکسی سیستم یا kill switch.
- **Helper دسترسی مدیر:** نسخه‌های امضاشده توسط اپل از یک helper ‏`SMAppService` استفاده می‌کنند که یک بار تأییدش می‌کنید؛ V2Mac هرگز رمز مدیر شما را نمی‌بیند یا ذخیره نمی‌کند.
- **پشتیبان‌گیری:** خروجی گرفتن از اشتراک‌ها، سرورها، علاقه‌مندی‌ها و تنظیمات در یک فایل `.v2m` و بازگردانی روی مک دیگر.
- **و همچنین:** اشتراک‌گذاری روی LAN با رمز، کد QR، نمایشگر لاگ، اعلان‌ها، اجرا هنگام ورود، و به‌روزرسانی یک‌کلیکی برنامه و هستهٔ Xray.
- **زبان‌ها:** انگلیسی، فارسی (راست‌به‌چپ)، چینی ساده و روسی.
- **حریم خصوصی:** بدون آمارگیری و بدون ارسال داده. اطلاعات محرمانه در یک فایل محلی رمزنگاری‌شده یا، اگر بخواهید، در Keychain می‌ماند.

</div>

<div dir="rtl">

## تصاویر برنامه

همهٔ تصاویر با سرورهای ساختگی گرفته شده‌اند.

</div>

<p align="center"><img src="docs/images/screenshots/main.png" alt="پنجرهٔ اصلی V2Mac با گروه‌های اشتراک، تأخیر و سرعت سرورها، inspector و نوار اتصال" width="760"></p>

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshots/add-subscription.png" alt="پنجرهٔ افزودن اشتراک" width="380"><br><sub>افزودن اشتراک</sub></td>
    <td align="center"><img src="docs/images/screenshots/server-editor.png" alt="ویرایشگر سرور VLESS" width="380"><br><sub>ویرایش هر سرور</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshots/rule-builder-countries.png" alt="نقشهٔ جهان در Rule Builder با کشورهای انتخاب‌شده" width="380"><br><sub>Rule Builder: انتخاب کشور روی نقشه</sub></td>
    <td align="center"><img src="docs/images/screenshots/custom-rules.png" alt="قوانین مسیریابی سفارشی در تنظیمات" width="380"><br><sub>قوانین مسیریابی سفارشی</sub></td>
  </tr>
</table>

<details>
<summary><b>تصاویر بیشتر</b></summary>

<p align="center"><img src="docs/images/screenshots/settings-tour.gif" alt="گشتی در همهٔ تب‌های تنظیمات V2Mac" width="560"></p>
<p align="center"><img src="docs/images/screenshots/connection-settings.png" alt="تنظیمات اتصال: انتخاب خودکار سرور و رفتار هنگام خطای TUN" width="560"></p>
<p align="center"><img src="docs/images/screenshots/routing-settings.png" alt="تنظیمات مسیریابی با Bypass ایران" width="560"></p>
<p align="center"><img src="docs/images/screenshots/sharing.png" alt="کد QR سرور برای اشتراک‌گذاری" width="328"></p>

</details>

<div dir="rtl">

## جلوگیری از نشت اطلاعات در کروم: noleaker

پروکسی به‌تنهایی جلوی نشت مرورگر را نمی‌گیرد: WebRTC می‌تواند IP واقعی شما را لو بدهد، DNS و QUIC می‌توانند پروکسی را دور بزنند، و منطقهٔ زمانی و زبان محل شما را نشان می‌دهند. [**noleaker**](https://github.com/LordVersA/noleaker)، افزونهٔ رایگانی از همین سازنده، کنار V2Mac برای کروم و مرورگرهای Chromium کار می‌کند: ترافیک و DNS را از پروکسی SOCKS5 برنامه عبور می‌دهد، نشت WebRTC و QUIC را می‌بندد، منطقهٔ زمانی، زبان و موقعیت را با کشور سرور هماهنگ می‌کند، و اگر پروکسی قطع شود درخواست‌ها را مسدود می‌کند.

راه‌اندازی: [آخرین نسخه](https://github.com/LordVersA/noleaker/releases/latest) را نصب کنید، پروکسی `127.0.0.1:10808` را اضافه کنید و **Protection** را روشن کنید. نام کاربری و رمز پروکسی V2Mac را خالی بگذارید.

## پرسش‌های رایج

<details>
<summary><b>آیا V2Mac یک کلاینت V2Ray برای مک است؟</b></summary>

بله. V2Mac از [Xray-core](https://github.com/XTLS/Xray-core)، جانشین فعال هستهٔ V2Ray، استفاده می‌کند؛ پس لینک‌ها و اشتراک‌های V2Ray و Xray (VLESS، VMess، Trojan، Shadowsocks) و همچنین Hysteria2 و WireGuard را می‌خواند.
</details>

<details>
<summary><b>آیا از VLESS REALITY و XTLS Vision پشتیبانی می‌کند؟</b></summary>

بله، هم از لینک‌ها و هم در ویرایشگر سرور، همراه transportهای TCP، WebSocket، gRPC، HTTPUpgrade، XHTTP (SplitHTTP) و mKCP.
</details>

<details>
<summary><b>چطور همهٔ برنامه‌ها را، حتی آن‌هایی که تنظیم پروکسی ندارند، از پروکسی رد کنم؟</b></summary>

کلید **TUN** کنار منوی مسیریابی را روشن کنید. همهٔ برنامه‌ها و درخواست‌های DNS از سرور عبور می‌کنند. helper را یک بار تأیید کنید (نسخه‌های امضاشده) یا در هر نشست یک بار رمز مدیر را وارد کنید (نسخه‌های ad-hoc).
</details>

<details>
<summary><b>روی مک‌های اینتل یا macOS قدیمی‌تر کار می‌کند؟</b></summary>

خیر. V2Mac به macOS 26 یا جدیدتر روی Apple Silicon نیاز دارد.
</details>

<details>
<summary><b>چرا macOS می‌گوید برنامه باز نمی‌شود؟</b></summary>

فایل DMG ‏notarize نشده. از **Open Anyway** در Privacy & Security، دستور `xattr` بالا یا نصب با Homebrew استفاده کنید.
</details>

<details>
<summary><b>آیا V2Mac داده‌ای جمع می‌کند؟</b></summary>

خیر. هیچ آمارگیری یا ارسال داده‌ای ندارد. جز ترافیک خودتان، V2Mac فقط به آدرس اشتراک‌هایتان، به گیت‌هاب برای به‌روزرسانی و فایل‌های قوانین، و به یک سرویس IP عمومی برای بررسی خروجی پس از اتصال وصل می‌شود.
</details>

## ساخت از سورس

</div>

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

<div dir="rtl">

نیازمند Xcode 26 به بالا و [XcodeGen](https://github.com/yonaskolb/XcodeGen). طراحی در [docs/SPEC.md](docs/SPEC.md) است. تست‌های پکیج: `cd Packages/V2MacCore && swift test`.

گزارش باگ و pull request در [Issues](https://github.com/LordVersA/v2mac/issues) پذیرفته می‌شود.

## مجوز

[GPL-3.0](LICENSE). شامل [Xray-core](https://github.com/XTLS/Xray-core) ‏(MPL-2.0)؛ [THIRD_PARTY.md](THIRD_PARTY.md) را ببینید.

</div>

<p align="center"><sub>اگر V2Mac به کارتان آمد، یک ⭐ کمک می‌کند دیگران هم پیدایش کنند.</sub></p>
