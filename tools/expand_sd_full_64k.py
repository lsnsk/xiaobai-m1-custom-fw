#!/usr/bin/env python3
"""
Расширение карты MicroSD 64 / 128 / 256 ГБ до полного объёма с эталонным
FAT32 (кластер РОВНО 64 КБ, BPB_SecPerClus=128, MBR 0x0B, StartLBA 2048,
занулённый GPT EFI PART LBA 1..33), который штатный HIBERRY FSTOOL принимает без ошибок.

Запускается в Test Mode по USB RNDIS (после connect_rndis.bat).
Автоматически сохраняет /app/sd/eye.conf в ОЗУ и восстанавливает его после форматирования!
ВНИМАНИЕ: все остальные файлы на карте памяти (записи и бэкапы) будут удалены — заранее
скопируйте SD:/backup_orig/ на компьютер!
"""
import argparse
import os
import re
import socket
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rndis_utils import (
    LOCAL_IP,
    PEER_IP,
    bind_rndis_socket,
    build_fat32_64k_headers,
    detect_rndis_ifindex,
    upload_bytes_via_nc,
)


def connect_telnet():
    ifindex = detect_rndis_ifindex()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    bind_rndis_socket(s, LOCAL_IP, ifindex, auto_detect=False)
    s.connect((PEER_IP, 23))
    time.sleep(0.35)
    s.recv(4096)
    s.sendall(b"root\n")
    time.sleep(0.35)
    s.recv(4096)
    s.sendall(b"admin\n")
    time.sleep(0.45)
    s.recv(4096)
    return s, ifindex


def run_cmd(s, cmd, timeout=120):
    print(f"\n>>> {cmd}")
    s.sendall((cmd + "; echo __DONE__$((100+23)):$?:END__\n").encode("utf-8"))
    s.settimeout(2.0)
    t0 = time.time()
    buf = ""
    while time.time() - t0 < timeout:
        try:
            chunk = s.recv(4096).decode("utf-8", "replace")
            if chunk:
                sys.stdout.write(chunk)
                sys.stdout.flush()
                buf += chunk
                if "__DONE__123:" in buf and ":END__" in buf.split("__DONE__123:", 1)[1]:
                    return buf
        except socket.timeout:
            continue
    raise TimeoutError(f"Timeout: {cmd}")


def main():
    ap = argparse.ArgumentParser(description="Expand 64-256GB microSD to full FAT32 (64KB cluster, MBR 0x0B)")
    ap.add_argument("--yes", action="store_true", help="Подтвердить форматирование карты MicroSD без интерактива")
    ap.add_argument("--keep-testmode", action="store_true", help="Оставить Test Mode включённым после перезагрузки")
    args = ap.parse_args()

    if not args.yes:
        print("ВНИМАНИЕ! Скрипт переразметит и отформатирует ВСЮ карту MicroSD внутри глазка.")
        print("Файл eye.conf будет автоматически сохранён в ОЗУ и восстановлен,")
        print("НО все записи и папка backup_orig на карте будут стёрты — сохраните backup_orig на ПК!")
        ans = input("Введите YES для продолжения: ").strip()
        if ans != "YES":
            print("Отменено.")
            return 1

    s, ifindex = connect_telnet()
    try:
        # 1. Сохраняем eye.conf (если есть) в /tmp перед размонтированием
        run_cmd(
            s,
            "mkdir -p /app/sd; "
            "(grep -q ' /app/sd ' /proc/mounts || mount -t vfat /dev/mmcblk0p1 /app/sd 2>/dev/null || true); "
            "rm -f /tmp/eye.conf.saved; "
            "[ -f /app/sd/eye.conf ] && cp -f /app/sd/eye.conf /tmp/eye.conf.saved && echo SAVED_EYE_CONF || echo NO_EYE_CONF",
        )

        # 2. Размонтируем /app/sd, зануляем остаточный GPT LBA 1..33, создаём один MBR 0x0B раздел с StartLBA 2048
        run_cmd(s, "sync; umount /app/sd 2>/dev/null || umount -l /app/sd 2>/dev/null || true")
        run_cmd(s, "dd if=/dev/zero of=/dev/mmcblk0 bs=512 seek=1 count=33 conv=notrunc && sync")
        run_cmd(s, 'echo -e "d\\n1\\nd\\n2\\nd\\n3\\nd\\nn\\np\\n1\\n\\n\\nt\\nb\\nx\\nb\\n1\\n2048\\nY\\nw\\n" | fdisk /dev/mmcblk0')
        run_cmd(s, "fdisk -l /dev/mmcblk0")

        # 3. Записываем эталонные заголовки FAT32 (кластер 64 КБ = 128 секторов)
        sz_out = run_cmd(s, 'echo __SZ_$((20+1)):$(cat /sys/class/block/mmcblk0p1/size):$(cat /sys/class/block/mmcblk0p1/start):END__')
        m_sz = re.search(r"__SZ_21:(\d+):(\d+):END__", sz_out)
        assert m_sz, f"Не удалось прочитать геометрию mmcblk0p1: {sz_out}"
        tot_sec, hidd_sec = int(m_sz.group(1)), int(m_sz.group(2))
        rsvd_blob, fat_head, fat_sz32, num_clus, wipe_64k = build_fat32_64k_headers(tot_sec, hidd_sec, "IPC018")
        print(f"\n[*] FAT32 64KB geometry: tot_sec={tot_sec}, fat_sz32={fat_sz32}, num_clus={num_clus}, wipe_64k={wipe_64k}")

        run_cmd(s, f"dd if=/dev/zero of=/dev/mmcblk0p1 bs=65536 count={wipe_64k}")
        upload_bytes_via_nc(s, rsvd_blob, "/tmp/fat_rsvd.bin", 9191, LOCAL_IP, PEER_IP, ifindex)
        upload_bytes_via_nc(s, fat_head, "/tmp/fat_head.bin", 9192, LOCAL_IP, PEER_IP, ifindex)
        run_cmd(
            s,
            f"dd if=/tmp/fat_rsvd.bin of=/dev/mmcblk0p1 bs=512 seek=0 conv=notrunc && "
            f"dd if=/tmp/fat_head.bin of=/dev/mmcblk0p1 bs=512 seek=32 conv=notrunc && "
            f"dd if=/tmp/fat_head.bin of=/dev/mmcblk0p1 bs=512 seek={32 + fat_sz32} conv=notrunc && "
            f"rm -f /tmp/fat_rsvd.bin /tmp/fat_head.bin && sync",
        )

        # 4. Монтируем, восстанавливаем eye.conf, снимаем Test Mode (если не указан --keep-testmode) и перезагружаем
        run_cmd(s, "mkdir -p /app/sd && mount -t vfat /dev/mmcblk0p1 /app/sd && df -h /app/sd")
        run_cmd(s, "[ -f /tmp/eye.conf.saved ] && cp -f /tmp/eye.conf.saved /app/sd/eye.conf && sync && echo RESTORED_EYE_CONF || true")
        if not args.keep_testmode:
            run_cmd(s, "rm -f /app/sd/IPC018_TESTMODE.file && /app/bin/factory set test 0 && sync")
        run_cmd(s, "sync; umount /app/sd 2>/dev/null || true")
        s.sendall(b"reboot -f\n")
        time.sleep(2.0)
        print("\n[OK] Карта расширена до полного объёма (FAT32, кластер 64 КБ) и глазок перезагружается!")
    finally:
        s.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
