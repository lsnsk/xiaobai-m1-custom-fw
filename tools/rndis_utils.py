#!/usr/bin/env python3
"""
Shared USB RNDIS & FAT32 (64 KB cluster) helpers for
Xiaomi Xiaobai Smart Cat Eye M1 (CMMY18A / chuangmi.cateye.ipc018).
"""
import socket
import struct
import subprocess
import sys
import time
from typing import Optional

LOCAL_IP = "192.168.0.2"
PEER_IP = "192.168.0.1"
IP_UNICAST_IF = 31


def detect_rndis_ifindex() -> Optional[int]:
    """Return Windows interface index for the active USB RNDIS adapter, if present."""
    if sys.platform != "win32":
        return None
    ps_cmd = (
        "(Get-NetAdapter | Where-Object { "
        "$_.InterfaceDescription -match 'NDIS' -and $_.Status -eq 'Up' "
        "} | Select-Object -First 1).ifIndex"
    )
    try:
        res = subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps_cmd],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return None
    out = res.stdout.strip()
    return int(out) if out.isdigit() else None


def bind_rndis_socket(
    s: socket.socket,
    local_ip: str = LOCAL_IP,
    ifindex: Optional[int] = None,
    *,
    auto_detect: bool = True,
) -> None:
    """Bind socket to local RNDIS IP and pin IP_UNICAST_IF on Windows (avoids 192.168.0.1 LAN collision)."""
    if ifindex is None and auto_detect:
        ifindex = detect_rndis_ifindex()
    if sys.platform == "win32" and ifindex is not None:
        s.setsockopt(socket.IPPROTO_IP, IP_UNICAST_IF, struct.pack("!I", ifindex))
    s.bind((local_ip, 0))


def upload_bytes_via_nc(
    telnet_sock: socket.socket,
    data: bytes,
    remote_path: str,
    port: int,
    local_ip: str = LOCAL_IP,
    peer_ip: str = PEER_IP,
    ifindex: Optional[int] = None,
    timeout: int = 60,
) -> None:
    """Stream raw bytes into remote_path on the peephole using BusyBox nc."""
    telnet_sock.sendall(
        f"killall nc 2>/dev/null || true; rm -f '{remote_path}'; "
        f"(nc -l -p {port} > '{remote_path}') >/dev/null 2>&1 &\n".encode("utf-8")
    )
    time.sleep(0.45)
    ds = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ds.settimeout(timeout)
    bind_rndis_socket(ds, local_ip, ifindex, auto_detect=(ifindex is None))
    try:
        ds.connect((peer_ip, port))
        ds.sendall(data)
        try:
            ds.shutdown(socket.SHUT_WR)
        except OSError:
            pass
    finally:
        ds.close()
    time.sleep(0.4)


def build_fat32_64k_headers(tot_sec: int, hidd_sec: int = 2048, label: str = "IPC018"):
    """
    Build Microsoft FAT32 + HIBERRY FSTOOL 2.0.1.0 compliant 64 KB cluster headers:
      - BPB_BytsPerSec = 512, BPB_SecPerClus = 128 (65,536 B / cluster)
      - BPB_RsvdSecCnt = 32, BPB_NumFATs = 2, BPB_RootClus = 2, FSInfo = 1, BkBootSec = 6
      - FSInfo FSI_Free_Count = num_clus - 1, FSI_Nxt_Free = 2 (matches HI_FSTOOL_Format)
    Returns (rsvd_blob_16384B, fat_head_512B, fat_sz32, num_clus, wipe_64k_blocks).
    """
    assert tot_sec >= 66000 * 8 and tot_sec <= 0xFFFFFFFF, f"Invalid tot_sec={tot_sec}"
    sec_per_clus = 128
    while sec_per_clus > 8 and (tot_sec // sec_per_clus) < 65600:
        sec_per_clus //= 2

    rsvd_sec = 32
    num_fats = 2
    tmp1 = tot_sec - rsvd_sec
    tmp2 = (256 * sec_per_clus + num_fats) // 2
    fat_sz32 = ((tmp1 + tmp2 - 1) // tmp2 + 7) & ~7
    data_sec = tot_sec - rsvd_sec - num_fats * fat_sz32
    num_clus = data_sec // sec_per_clus
    while fat_sz32 * 128 < (num_clus + 2):
        fat_sz32 += 8
        data_sec = tot_sec - rsvd_sec - num_fats * fat_sz32
        num_clus = data_sec // sec_per_clus

    vol_lbl = label.upper().encode("ascii", "ignore")[:11].ljust(11, b" ")
    vol_id = (int(time.time()) ^ 0x6AF6018C) & 0xFFFFFFFF

    boot = bytearray(512)
    boot[0:3] = b"\xEB\x58\x90"
    boot[3:11] = b"MSWIN4.1"
    struct.pack_into("<H", boot, 0x0B, 512)
    boot[0x0D] = sec_per_clus
    struct.pack_into("<H", boot, 0x0E, rsvd_sec)
    boot[0x10] = num_fats
    boot[0x15] = 0xF8
    struct.pack_into("<H", boot, 0x18, 63)
    struct.pack_into("<H", boot, 0x1A, 255)
    struct.pack_into("<I", boot, 0x1C, hidd_sec)
    struct.pack_into("<I", boot, 0x20, tot_sec)
    struct.pack_into("<I", boot, 0x24, fat_sz32)
    struct.pack_into("<I", boot, 0x2C, 2)
    struct.pack_into("<H", boot, 0x30, 1)
    struct.pack_into("<H", boot, 0x32, 6)
    boot[0x40] = 0x80
    boot[0x41] = 0x00
    boot[0x42] = 0x29
    struct.pack_into("<I", boot, 0x43, vol_id)
    boot[0x47:0x52] = vol_lbl
    boot[0x52:0x5A] = b"FAT32   "
    boot[0x1FE:0x200] = b"\x55\xAA"

    fsinfo = bytearray(512)
    struct.pack_into("<I", fsinfo, 0x000, 0x41615252)
    struct.pack_into("<I", fsinfo, 0x1E4, 0x61417272)
    struct.pack_into("<I", fsinfo, 0x1E8, num_clus - 1)
    struct.pack_into("<I", fsinfo, 0x1EC, 2)
    fsinfo[0x1FE:0x200] = b"\x55\xAA"

    rsvd_blob = bytearray(rsvd_sec * 512)
    rsvd_blob[0 * 512 : 1 * 512] = boot
    rsvd_blob[1 * 512 : 2 * 512] = fsinfo
    rsvd_blob[6 * 512 : 7 * 512] = boot
    rsvd_blob[7 * 512 : 8 * 512] = fsinfo

    fat_head = bytearray(512)
    struct.pack_into("<3I", fat_head, 0, 0x0FFFFFF8, 0x0FFFFFFF, 0x0FFFFFFF)

    wipe_sectors = rsvd_sec + num_fats * fat_sz32 + 2 * sec_per_clus
    wipe_64k_blocks = (wipe_sectors * 512 + 65535) // 65536
    return bytes(rsvd_blob), bytes(fat_head), fat_sz32, num_clus, wipe_64k_blocks


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        rsvd, fat, fsz, ncl, wipe = build_fat32_64k_headers(131072000, 2048, "IPC018")
        assert len(rsvd) == 16384 and len(fat) == 512 and rsvd[0x0D] == 128
        print(f"SELFTEST OK: rsvd={len(rsvd)}B fat_sz32={fsz} num_clus={ncl} wipe_64k={wipe} secPerClus={rsvd[0x0D]}")
