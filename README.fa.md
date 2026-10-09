<p align="center"><img src="docs/images/banner.jpg" alt="V2Mac، کلاینت بومی Xray-core برای macOS با پشتیبانی از VLESS، VMess، Trojan، Shadowsocks و Hysteria2" width="720"></p>

<p align="center"><a href="README.md">English</a> | فارسی</p>

<div dir="rtl">

# V2Mac

**کلاینت بومی macOS برای [Xray-core](https://github.com/XTLS/Xray-core).** لینک اشتراک را وارد کنید، یک سرور انتخاب کنید و یک پروکسی محلی SOCKS5 و HTTP تحویل بگیرید. با SwiftUI و Liquid Glass ساخته شده، برای مک‌های Apple Silicon.

## امکانات

- **اشتراک‌ها:** لینک‌های VLESS، VMess، Trojan، Shadowsocks، Hysteria2، WireGuard و SOCKS/HTTP ساده، و همچنین کانفیگ کامل JSON برای Xray را وارد می‌کند. به‌روزرسانی خودکار دارد و اگر سرویس‌دهنده اعلام کند، حجم مصرف‌شده و تاریخ انقضا را نشان می‌دهد.
- **تست تأخیر:** تست Real Delay و TCP Ping برای کل یک گروه به‌صورت یک‌جا، مرتب‌شده بر اساس سرعت.
- **مسیریابی:** حالت Global، حالت Direct، یا دور زدن منطقه‌ای (ایران هم هست) تا ترافیک داخلی مستقیم برود.
- **حالت TUN:** با یک کلید، تمام ترافیک مک از پروکسی رد می‌شود؛ حتی برنامه‌هایی که تنظیم پروکسی ندارند. نیازی به حساب پولی توسعه‌دهنده یا System Extension نیست.
- **کنترل از نوار منو:** اتصال، تعویض سرور، سرعت لحظه‌ای و آدرس محلی که می‌شود کپی کرد.
- **پایدار:** بعد از کرش، خواب سیستم یا تغییر شبکه هسته را دوباره راه می‌اندازد و هنگام باز شدن برنامه دوباره وصل می‌شود.
- **و همچنین:** اشتراک‌گذاری روی شبکه محلی با رمز، کد QR، نمایش لاگ، اجرا هنگام ورود به سیستم، و به‌روزرسانی برنامه و هسته Xray با یک کلیک.
- **خصوصی:** بدون هیچ آمارگیری یا تله‌متری.

## نصب

به macOS 26 یا جدیدتر روی Apple Silicon نیاز دارد.

1. فایل `V2Mac-<version>.dmg` را از [Releases](../../releases) دانلود کنید و **V2Mac** را به پوشه **Applications** بکشید.
2. برنامه notarize نشده است، پس macOS اولین اجرا را مسدود می‌کند. یک بار آن را باز کنید، سپس به **System Settings → Privacy & Security** بروید و روی **Open Anyway** بزنید. یا این دستور را در Terminal اجرا کنید:

   ```sh
   xattr -dr com.apple.quarantine /Applications/V2Mac.app
   ```

3. روی **Add Subscription** بزنید، لینک خود را وارد کنید و برای اتصال روی یک سرور دوبار کلیک کنید.
4. برنامه‌هایتان را روی `socks5://127.0.0.1:10808` یا `http://127.0.0.1:10808` تنظیم کنید.

اگر می‌خواهید کل مک از پروکسی رد شود، کلید **TUN** را کنار منوی مسیریابی روشن کنید. macOS در هر بار باز شدن V2Mac یک بار رمز مدیر سیستم را می‌پرسد؛ چیزی روی سیستم نصب نمی‌شود.

بستن پنجره پروکسی را قطع نمی‌کند. برای توقف، با ⌘Q از برنامه خارج شوید.

## ساخت از سورس

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

به Xcode 26 یا جدیدتر و [XcodeGen](https://github.com/yonaskolb/XcodeGen) نیاز دارد. طراحی برنامه در [docs/SPEC.md](docs/SPEC.md) آمده است (به انگلیسی).

## مجوز

GPL-3.0. فایل‌های [LICENSE](LICENSE) و [THIRD_PARTY.md](THIRD_PARTY.md) را ببینید.

</div>
