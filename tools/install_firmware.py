#!/usr/bin/env python3
"""
Автоматический бэкап родной прошивки (mtd0..mtd7) и безопасная прошивка
умного видеоглазка Xiaomi Xiaobai Smart Cat Eye M1 (CMMY18A / ipc018) по USB RNDIS.

Использование:
  1. Скопируйте выбранный вариант прошивки (landscape или portrait) на MicroSD (FAT32, кластер 64 КБ)
     в папку /patch_435/ и создайте пустой файл IPC018_TESTMODE.file в корне SD.
  2. Вставьте карту в глазок (USB-кабель ОТКЛЮЧЁН!), включите/перезапустите его кнопкой питания Power
     от батареи, дождитесь пустого подсвеченного экрана Test Mode (~10-12 сек), и ТОЛЬКО ПОСЛЕ ЭТОГО
     подключите кабель Micro-USB к ПК и запустите connect_rndis.bat.
  3. Запустите: python install_firmware.py
  4. После отключения USB обязательно запустите cleanup_rndis_route.ps1.
"""
import argparse
import os
import socket
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rndis_utils import LOCAL_IP, PEER_IP, bind_rndis_socket, detect_rndis_ifindex

PEER_PORT = 23


def open_session() -> socket.socket:
    print(f"[*] Подключение к глазку {PEER_IP}:{PEER_PORT} (USB RNDIS)...")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(8)
    try:
        bind_rndis_socket(s, LOCAL_IP, detect_rndis_ifindex(), auto_detect=False)
    except OSError:
        pass
    s.connect((PEER_IP, PEER_PORT))
    time.sleep(0.35)
    s.recv(4096)
    s.sendall(b"root\n")
    time.sleep(0.35)
    s.recv(4096)
    s.sendall(b"admin\n")
    time.sleep(0.45)
    banner = s.recv(4096).decode("utf-8", "replace")
    if "incorrect" in banner.lower():
        raise RuntimeError("Не удалось авторизоваться по Telnet (проверьте режим Test Mode).")
    print("[OK] Соединение с глазком установлено!")
    return s


def run_cmd(s: socket.socket, cmd: str, timeout: int = 300) -> str:
    marker = "__EYE_RC_123:"
    full = f"{cmd}; echo __EYE_RC_$((100+23)):$?:END__\n"
    s.sendall(full.encode("utf-8"))
    s.settimeout(2.0)
    t0 = time.time()
    buf = ""
    while time.time() - t0 < timeout:
        try:
            chunk = s.recv(4096).decode("utf-8", "replace")
            if not chunk:
                break
            sys.stdout.write(chunk)
            sys.stdout.flush()
            buf += chunk
            if marker in buf and ":END__" in buf.split(marker, 1)[1]:
                rc_str = buf.split(marker, 1)[1].split(":END__", 1)[0].strip()
                if rc_str != "0":
                    raise RuntimeError(f"Команда завершилась с кодом {rc_str}: {cmd}")
                return buf
        except socket.timeout:
            continue
    raise TimeoutError(f"Превышено время ожидания ({timeout} с) для команды: {cmd}")


def main():
    ap = argparse.ArgumentParser(description="Xiaomi Xiaobai Cat Eye M1 Safe Flasher (4.3.5_3319 RU)")
    ap.add_argument(
        "--keep-testmode",
        action="store_true",
        help="Оставить Test Mode (USB RNDIS) включённым после перезагрузки для проверки",
    )
    args = ap.parse_args()

    s = open_session()

    print("\n[1/5] Подготовка ОЗУ (/tmp) и проверка папки /app/sd/patch_435...")
    run_cmd(
        s,
        "mkdir -p /app/sd /tmp/lib && "
        "(mount | grep -q '/app/sd' || mount -t vfat /dev/mmcblk0p1 /app/sd 2>/dev/null || mount -t vfat /dev/mmcblk0 /app/sd 2>/dev/null || true) && "
        "test -f /app/sd/patch_435/MD5SUMS.txt && "
        "(cp -a /lib/* /tmp/lib/ 2>/dev/null || true) && "
        "cp /bin/busybox /tmp/busybox && cp /app/bin/upmtd /tmp/upmtd && cp /app/bin/factory /tmp/factory && "
        "chmod 755 /tmp/busybox /tmp/upmtd /tmp/factory",
        timeout=30,
    )

    print("\n[2/5] Проверка резервной копии родной прошивки в /app/sd/backup_orig...")
    run_cmd(
        s,
        "if [ ! -s /app/sd/backup_orig/mtd7_rootfs.squashfs ]; then "
        "  echo '[*] Создаём полный бэкап всех 8 разделов флеш-памяти в /app/sd/backup_orig...'; "
        "  mkdir -p /app/sd/backup_orig && "
        "  dd if=/dev/mtd0 of=/app/sd/backup_orig/mtd0_uboot.bin bs=65536 && "
        "  dd if=/dev/mtd1 of=/app/sd/backup_orig/mtd1_rawparam.bin bs=65536 && "
        "  dd if=/dev/mtd2 of=/app/sd/backup_orig/mtd2_rawparambak.bin bs=65536 && "
        "  dd if=/dev/mtd3 of=/app/sd/backup_orig/mtd3_config.bin bs=65536 && "
        "  dd if=/dev/mtd4 of=/app/sd/backup_orig/mtd4_factory.bin bs=65536 && "
        "  dd if=/dev/mtd5 of=/app/sd/backup_orig/mtd5_media_app_zip.bin bs=65536 && "
        "  dd if=/dev/mtd6 of=/app/sd/backup_orig/mtd6_uImage.bin bs=65536 && "
        "  dd if=/dev/mtd7 of=/app/sd/backup_orig/mtd7_rootfs.squashfs bs=65536 && "
        "  (cd /app/sd/backup_orig && md5sum mtd* > MD5SUMS_BACKUP.txt) && sync; "
        "else "
        "  echo '[OK] Полный бэкап в /app/sd/backup_orig уже существует — не перезаписываем.'; "
        "fi",
        timeout=180,
    )

    print("\n[3/5] Проверка контрольных сумм MD5 файлов прошивки на MicroSD...")
    run_cmd(s, "cd /app/sd/patch_435 && LD_LIBRARY_PATH=/tmp/lib /tmp/busybox md5sum -c MD5SUMS.txt", timeout=60)
    print("\n[OK] Все контрольные суммы MD5 совпали 100%!")

    print("\n[4/5] Запись /dev/mtd5 (media_app_zip.bin)...")
    out5 = run_cmd(s, "LD_LIBRARY_PATH=/tmp/lib /tmp/upmtd /app/sd/patch_435/media_app_zip.bin /dev/mtd5", timeout=240)
    assert "Verifying kb:" in out5 and "(100%)" in out5, "Ошибка верификации /dev/mtd5!"

    print("\n[4b/5] Проверка /dev/mtd6 (ядро Linux uImage 4.3.5_3319)...")
    out6 = run_cmd(
        s,
        "CUR6=$(LD_LIBRARY_PATH=/tmp/lib /tmp/busybox md5sum /dev/mtd6 | LD_LIBRARY_PATH=/tmp/lib /tmp/busybox awk '{print $1}'); "
        "NEW6=$(LD_LIBRARY_PATH=/tmp/lib /tmp/busybox md5sum /app/sd/patch_435/uImage.bin | LD_LIBRARY_PATH=/tmp/lib /tmp/busybox awk '{print $1}'); "
        "if [ \"$CUR6\" = \"$NEW6\" ]; then "
        "  echo '[OK] Ядро /dev/mtd6 уже соответствует 4.3.5_3319 — перезапись не требуется (Verifying kb: 100%).'; "
        "else "
        "  LD_LIBRARY_PATH=/tmp/lib /tmp/upmtd /app/sd/patch_435/uImage.bin /dev/mtd6; "
        "fi",
        timeout=240,
    )
    assert "(100%)" in out6, "Ошибка верификации /dev/mtd6!"

    print("\n[4c/5] Снятие флага Test Mode (при необходимости) и запись /dev/mtd7 (rootfs.squashfs)...")
    if not args.keep_testmode:
        run_cmd(
            s,
            "rm -f /app/sd/IPC018_TESTMODE.file /mnt/sdcard/IPC018_TESTMODE.file && "
            "/app/bin/factory set test 0 && sync",
            timeout=20,
        )
        print("[OK] Флаг Test Mode снят (глазок загрузится сразу в рабочий режим).")
    else:
        print("[*] Флаг Test Mode оставлен включённым (--keep-testmode).")

    out7 = run_cmd(s, "LD_LIBRARY_PATH=/tmp/lib /tmp/upmtd /app/sd/patch_435/rootfs.squashfs /dev/mtd7", timeout=300)
    assert "Verifying kb:" in out7 and "(100%)" in out7, "Ошибка верификации /dev/mtd7!"

    print("\n[5/5] Синхронизация SD и перезагрузка...")
    run_cmd(
        s,
        "LD_LIBRARY_PATH=/tmp/lib /tmp/busybox sync && "
        "(LD_LIBRARY_PATH=/tmp/lib /tmp/busybox umount /app/sd 2>/dev/null || true)",
        timeout=30,
    )
    s.sendall(b"(LD_LIBRARY_PATH=/tmp/lib /tmp/busybox reboot -f) >/dev/null 2>&1 &\n")
    time.sleep(3.0)
    s.close()
    print("\n==================================================================")
    print(" ГОТОВО! Прошивка успешно установлена и проверена на 100%!")
    print(" Отсоедините USB-кабель и запустите cleanup_rndis_route.ps1.")
    print(" Обязательно сохраните папку SD:/backup_orig/ на ПК в надёжное место!")
    print("==================================================================")


if __name__ == "__main__":
    main()
