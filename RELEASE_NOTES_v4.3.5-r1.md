# Xiaobai Smart Cat Eye M1 (`CMMY18A`) — Autonomous Russian Firmware `4.3.5_3319` (`v4.3.5-r1`)

Готовый релиз полностью русифицированной автономной прошивки **`4.3.5_3319` (Modern Slate Dark UI)** для умного видеоглазка **Xiaomi / IMILAB Xiaobai Smart Cat Eye M1 (`CMMY18A` / `chuangmi.cateye.ipc018`)**.

## Что включено в релиз

- **Горизонтальная (`854×480`) и Вертикальная `90° CW` (`480×854`) сборки** с русским Slate Dark UI, кириллическими `.ubf`-шрифтами, русскими заставками LiteOS (`mtd5`) и озвучкой `ru-RU-DmitryNeural`.
- **4-кнопочная нижняя панель главного экрана (`Снимок | Запись | Записи | Настройки`)** — запись H.265 + G.711 A-law (ISO 14496-12) с автоподъёмом/остановкой VENC, атомарные повёрнутые миниатюры и снимки `/app/sd/snapshots/`.
- **Полная автономия (`MI_CLOUD_ENABLE=0`, `< 1 мА` во сне)** с аппаратным Wi-Fi keepalive (`HEARTBEAT_SERVERS="auto:9999"`, `< 0.35 мА·ч/сутки`) для 24/7 пробуждения по **WoWLAN**, либо параллельная работа с Mi Home (`MI_CLOUD_ENABLE=1`).
- **Telegram-пульт + живой голосовой интерком (`🎙` → внешний динамик через `libopus`) + семейные группы** (исправлена отправка HTML-подписей через `curl --form-string`).
- **Home Assistant (`MQTT Auto-Discovery`, 10 объектов)**, **FTP/WebDAV бэкап на NAS**, **Web-портал `http://<IP>:8080`** (MJPEG, галерея `/snapshots/`, кнопка `🎬 Запись 10с`).
- **Поддержка карт MicroSD `64 / 128 / 256 ГБ` (`FAT32`, кластер `64 КБ`, `MBR 0x0B`)** и **безопасные Wi-Fi OTA-обновления `mtd7`** (`tools/ota_update_wifi.py` → `IPC018_UPDATE.file` в `S00devs`).
- **Круглосуточный OpenWrt-бот** (`xiaobai-m1-openwrt-bot.zip`) и **аварийный пакет восстановления за 2 минуты** (`xiaobai-m1-4.0.9_2313-unbrick-sd.zip`).

## Контрольные суммы образов `4.3.5_3319` (MD5)

| Вариант | `media_app_zip.bin` | `uImage.bin` | `rootfs.squashfs` |
| :--- | :--- | :--- | :--- |
| **Landscape (`854×480`)** | `1ed4f5c7195183e7904e6dce09084b6d` | `ab4a852abaf9ae5d89bee48c8a6107a6` | `6f78cc6d76f39071092e068632c573b1` |
| **Portrait (`480×854`)** | `38086479cac5cdcafaba3fdf758bd744` | `ab4a852abaf9ae5d89bee48c8a6107a6` | `2195c45ada904e68c0d9acfda4065a29` |

## Архивы релиза (SHA-256)

| Файл | Размер | SHA-256 |
| :--- | :--- | :--- |
| `xiaobai-m1-4.0.9_2313-unbrick-sd.zip` | 12.70 МБ | `716fbd2bedf3ac55b26aa739d667fc45b720f4a2db210346dd5b920ebad2933d` |
| `xiaobai-m1-4.3.5_3319-landscape.zip` | 12.77 МБ | `e081956fbbdd282779348901dfbac4c615f03b3518450a474d134af3a82aec08` |
| `xiaobai-m1-4.3.5_3319-portrait.zip` | 12.78 МБ | `49d9c5ac2b21537fb586207100f69a3378ce40e24dc77a752028f8383a11c77b` |
| `xiaobai-m1-openwrt-bot.zip` | 0.02 МБ | `0bc5307931fbc4ddc99719e3b99ad670155598738b2ffd8226b9e3700d1a4e15` |

> Подробная пошаговая инструкция по установке, кнопкам корпуса (`Home` + `Power` на торце, **без отверстия Reset**), Wi-Fi OTA и восстановлению — внутри архивов (`INSTALL_RU.md`, `RECOVERY_RU.md`, `FAQ_RU.md`) и в папке [`docs/`](docs/).
