# README gallery

Captured on macOS from V2MacDev with `-debugDemoData YES`. All servers, subscription usage, latency, and speed values are fixtures, not live measurements. No server was connected and TUN stayed off. The development proxy port is 10818; the installed app defaults to 10808.

The PNGs are window screenshots from the computer-use tool, including native glass effects. `sharing.png` is cropped to the inspector and its complete QR popover. `main.png` is reduced to 1440 pixels wide; the other PNGs retain their captured resolution.

The GIFs show captured UI states, held for three seconds per step and looped:

- `server-browsing.gif`: subscription → sort by delay → Favorites → search for Frankfurt.
- `settings-tour.gif`: General → Proxy → Routing → Connection → Servers → Notifications → Core → About.

For future refreshes, build and launch only V2MacDev with demo data. Capture its windows using the computer-use tool; the `-debugSnapshot` hook omits glass effects. Open the QR popover in a maximized demo window so the whole popover is visible, then crop the captured image. Keep TUN off and use no real subscription URLs or credentials.

GIFs are encoded with FFmpeg at 960 pixels wide for server browsing and 840 pixels wide for settings, using a 128-color palette, Bayer dithering, and rectangle difference optimization. Update the gallery in all three root READMEs together, and verify that every image reference exists and both GIFs decode and loop.
