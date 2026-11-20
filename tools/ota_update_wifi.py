#!/usr/bin/env python3
"""
Безопасное OTA-обновление /dev/mtd7 (rootfs.squashfs) по домашнему Wi-Fi
БЕЗ снятия глазка с двери и БЕЗ USB-кабеля!

Как работает:
  1. Будит глазок по WoWLAN UDP (если спит), захватывает wakelock и ждёт монтирования /app/sd.
  2. Проверяет, что в /etc/init.d/S00devs на глазке уже есть безопасный хук IPC018_UPDATE.file.
  3. Загружает rootfs.squashfs и MD5SUMS.txt в /app/sd/patch_435/ и сверяет MD5 прямо на карте.
  4. Создаёт маркер /app/sd/IPC018_UPDATE.file, делает sync и reboot -f.
  5. На старте S00devs прошивает /dev/mtd7 целиком из RAM (до запуска любых демонов!),
     удаляет маркер и через ~2 минуты глазок возвращается в сеть уже с новой версией.

Использование:
  python ota_update_wifi.py --host 192.168.1.50 --dir ../out_patch_435_portrait
"""
import argparse
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
IP_UNICAST_IF = 31


def detect_lan_for_target(target_ip: str):
    """Detect local source IPv4 (and Windows ifIndex) that routes to target_ip."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect((target_ip, 9999))
        lan_ip = probe.getsockname()[0]
    finally:
        probe.close()

    ifindex = None
    if sys.platform == "win32":
        ps = (
            f"Get-NetIPAddress -AddressFamily IPv4 -IPAddress '{lan_ip}' -ErrorAction SilentlyContinue | "
            "Select-Object -First 1 InterfaceIndex | ConvertTo-Json"
        )
        try:
            out = subprocess.check_output(["powershell", "-NoProfile", "-Command", ps], text=True, timeout=5).strip()
            if out:
                info = json.loads(out)
                ifindex = int(info["InterfaceIndex"])
        except Exception:
            ifindex = None
    return lan_ip, ifindex


def open_lan_tcp(host: str, port: int, lan_ip: str, ifindex, timeout: float = 10.0) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    if sys.platform == "win32" and ifindex is not None:
        s.setsockopt(socket.IPPROTO_IP, IP_UNICAST_IF, struct.pack("!I", ifindex))
    s.bind((lan_ip, 0))
    s.connect((host, port))
    return s


def tcp_open(host: str, port: int, lan_ip: str, ifindex, timeout: float = 0.8) -> bool:
    s = None
    try:
        s = open_lan_tcp(host, port, lan_ip, ifindex, timeout=timeout)
        return True
    except OSError:
        return False
    finally:
        if s is not None:
            s.close()


def send_wowlan(host: str, broadcast_ip: str, lan_ip: str, ifindex, key: str = "WAKEUP", port: int = 9999):
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        u.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        if sys.platform == "win32" and ifindex is not None:
            u.setsockopt(socket.IPPROTO_IP, IP_UNICAST_IF, struct.pack("!I", ifindex))
        u.bind((lan_ip, 0))
        payload = key.encode("utf-8")
        u.sendto(payload, (broadcast_ip, port))
        u.sendto(payload, (host, port))
    except OSError:
        pass
    finally:
        u.close()


class TelnetSession:
    def __init__(self, host: str, lan_ip: str, ifindex, port: int = 23):
        self.sock = open_lan_tcp(host, port, lan_ip, ifindex, timeout=10.0)
        self._login()

    def _read_until(self, needles, timeout=6.0):
        self.sock.settimeout(0.5)
        buf = b""
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                chunk = self.sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
                if any(n in buf for n in needles):
                    return buf.decode("utf-8", "replace")
            except socket.timeout:
                pass
        return buf.decode("utf-8", "replace")

    def _login(self):
        out = self._read_until([b"login:", b"# "], 6.0)
        if "login:" in out:
            self.sock.sendall(b"root\n")
            out2 = self._read_until([b"Password:", b"# "], 6.0)
            if "Password:" in out2:
                self.sock.sendall(b"admin\n")
                self._read_until([b"# "], 6.0)
        self.run("stty -echo 2>/dev/null || true", 5)

    def run(self, cmd: str, timeout: float = 30.0) -> str:
        tag = "__END_9271__"
        self.sock.sendall(f"{cmd}; echo __END_$((4000+5271))__\n".encode("utf-8"))
        self.sock.settimeout(1.0)
        buf = b""
        t0 = time.time()
        needle = tag.encode()
        while time.time() - t0 < timeout:
            try:
                chunk = self.sock.recv(8192)
                if not chunk:
                    break
                buf += chunk
                if needle in buf:
                    break
            except socket.timeout:
                pass
        text = buf.decode("utf-8", "replace")
        if tag not in text:
            raise TimeoutError(f"Timeout: {cmd}\nTail:\n{text[-300:]}")
        return text.split(tag)[0].strip()

    def send_raw(self, cmd: str):
        self.sock.sendall((cmd + "\n").encode("utf-8"))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def nc_upload(ts, host, lan_ip, ifindex, local_bytes, remote_path, port, timeout=120.0):
    ts.run(
        f"killall nc 2>/dev/null || true; rm -f '{remote_path}'; "
        f"(sleep 150 | nc -l -p {port} > '{remote_path}') >/dev/null 2>&1 &\n"
        f"echo BG_STARTED",
        10,
    )
    time.sleep(0.4)
    c = None
    last_err = None
    for _ in range(25):
        try:
            c = open_lan_tcp(host, port, lan_ip, ifindex, timeout=10.0)
            break
        except OSError as e:
            last_err = e
            time.sleep(0.2)
    if c is None:
        raise RuntimeError(f"nc connect failed on {port}: {last_err}")
    c.settimeout(90.0)
    c.sendall(local_bytes)
    try:
        c.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    c.close()

    want = len(local_bytes)
    t0 = time.time()
    last_sz = -1
    while time.time() - t0 < timeout:
        sz_out = ts.run(f"wc -c < '{remote_path}' 2>/dev/null || echo 0", 10)
        try:
            last_sz = int(sz_out.strip().splitlines()[-1])
        except Exception:
            last_sz = -1
        if last_sz == want:
            ts.run("killall nc 2>/dev/null || true; sync", 20)
            return last_sz
        time.sleep(0.5)
    ts.run("killall nc 2>/dev/null || true", 10)
    raise TimeoutError(f"nc upload timeout: {last_sz}/{want}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Safe Wi-Fi OTA mtd7 updater via S00devs IPC018_UPDATE.file")
    ap.add_argument("--host", required=True, help="IP-адрес глазка в домашней сети (например 192.168.1.50)")
    ap.add_argument("--dir", required=True, help="Папка с rootfs.squashfs и MD5SUMS.txt")
    ap.add_argument("--broadcast", default="", help="Broadcast подсети (по умолчанию X.X.X.255)")
    ap.add_argument("--wake-key", default="WAKEUP", help="Ключ WoWLAN (по умолчанию WAKEUP)")
    args = ap.parse_args()

    host = args.host.strip()
    bcast = args.broadcast.strip() or (".".join(host.split(".")[:3]) + ".255")
    src_dir = Path(args.dir)
    rootfs_path = src_dir / "rootfs.squashfs"
    md5_path = src_dir / "MD5SUMS.txt"
    if not rootfs_path.is_file() or not md5_path.is_file():
        print(f"[ERROR] В папке {src_dir} должны лежать rootfs.squashfs и MD5SUMS.txt")
        return 1

    rootfs_bytes = rootfs_path.read_bytes()
    md5_bytes = md5_path.read_bytes().replace(b"\r\n", b"\n")
    if len(rootfs_bytes) > 8388608:
        print(f"[ERROR] rootfs.squashfs превышает 8 МБ ({len(rootfs_bytes)} B)!")
        return 1
    exp_md5 = hashlib.md5(rootfs_bytes).hexdigest()

    lan_ip, ifindex = detect_lan_for_target(host)
    print(f"[*] LAN {lan_ip} (ifIndex={ifindex}) -> {host} (broadcast {bcast})")
    print(f"[*] rootfs.squashfs: {len(rootfs_bytes)} B, MD5={exp_md5}")

    if not tcp_open(host, 23, lan_ip, ifindex, 0.8):
        print("[*] Глазок спит — будим по WoWLAN...")
        for i in range(30):
            send_wowlan(host, bcast, lan_ip, ifindex, args.wake_key)
            time.sleep(0.7)
            if tcp_open(host, 23, lan_ip, ifindex, 0.8):
                print(f"[OK] Проснулся на попытке {i + 1}!")
                break
        else:
            print("[ERROR] Глазок не ответил на WoWLAN. Разбудите кнопкой Home и повторите.")
            return 2

    ts = TelnetSession(host, lan_ip, ifindex)
    try:
        ts.run(
            "rm -f /tmp/force_sleep_now; touch /tmp/eye_user_active; "
            "mortoxc set mem default max_client 1; "
            ". /app/eye/lib.sh; extend_awake 300",
            15,
        )
        for _ in range(15):
            if "MOUNTED" in ts.run("grep -q ' /app/sd ' /proc/mounts && echo MOUNTED || echo WAIT", 10):
                break
            time.sleep(1.0)
        else:
            raise RuntimeError("Карта /app/sd не смонтировалась!")

        chk = ts.run(
            "grep -c 'IPC018_UPDATE.file' /etc/init.d/S00devs; "
            "grep -c 'LD_LIBRARY_PATH=/tmp/lib /tmp/upmtd' /etc/init.d/S00devs",
            10,
        )
        nums = [int(x.strip()) for x in chk.splitlines() if x.strip().isdigit()]
        if len(nums) < 2 or nums[0] < 1 or nums[1] < 1:
            raise RuntimeError("На глазке старая версия S00devs без безопасного IPC018_UPDATE.file — прошейте первично по USB RNDIS!")

        ts.run("mkdir -p /app/sd/patch_435 && rm -f /app/sd/IPC018_UPDATE.file /app/sd/patch_435/rootfs.squashfs /app/sd/patch_435/MD5SUMS.txt", 15)
        print("[1/3] Загрузка rootfs.squashfs на MicroSD глазка...")
        nc_upload(ts, host, lan_ip, ifindex, rootfs_bytes, "/app/sd/patch_435/rootfs.squashfs", 9321)
        print("[2/3] Загрузка MD5SUMS.txt и проверка хэша на MicroSD...")
        nc_upload(ts, host, lan_ip, ifindex, md5_bytes, "/app/sd/patch_435/MD5SUMS.txt", 9322)

        ver = ts.run(
            "SPEC7=$(tr -d '\\r' < /app/sd/patch_435/MD5SUMS.txt | awk '$2==\"rootfs.squashfs\"{print $1}'); "
            "ACT7=$(md5sum /app/sd/patch_435/rootfs.squashfs | awk '{print $1}'); "
            "echo \"SPEC7=$SPEC7 ACT7=$ACT7\"",
            25,
        )
        print(f"  {ver}")
        if f"SPEC7={exp_md5}" not in ver or f"ACT7={exp_md5}" not in ver:
            raise RuntimeError(f"MD5 на SD не совпал: {ver}")

        print("[3/3] Создание маркера IPC018_UPDATE.file и перезагрузка для прошивки в S00devs...")
        ts.run(". /app/eye/lib.sh; mark_clean_reboot; touch /app/sd/IPC018_UPDATE.file; sync", 20)
        ts.send_raw("reboot -f")
        time.sleep(2.0)
    finally:
        ts.close()

    print("[*] Ожидание прошивки mtd7 и возврата глазка в сеть (~90-140 сек)...")
    t0 = time.time()
    time.sleep(35.0)
    while time.time() - t0 < 180:
        if tcp_open(host, 23, lan_ip, ifindex, 1.0):
            print(f"[OK] Глазок снова в сети через {time.time() - t0:.1f} с!")
            ts2 = TelnetSession(host, lan_ip, ifindex)
            try:
                ts2.run(
                    "rm -f /tmp/force_sleep_now; touch /tmp/eye_user_active; "
                    "mortoxc set mem default max_client 1; . /app/eye/lib.sh; extend_awake 60",
                    15,
                )
                for _ in range(12):
                    if "MOUNTED" in ts2.run("grep -q ' /app/sd ' /proc/mounts && echo MOUNTED || echo WAIT", 10):
                        break
                    time.sleep(1.0)
                st = ts2.run("ls -la /app/sd/IPC018_UPDATE.file 2>&1 || true; rm -rf /app/sd/patch_435; sync", 15)
                print(st)
                ts2.run("rm -f /tmp/eye_user_active; mortoxc set mem default max_client 0", 15)
            finally:
                ts2.close()
            print("[SUCCESS] OTA-обновление mtd7 завершено, wakelock освобождён!")
            return 0
        send_wowlan(host, bcast, lan_ip, ifindex, args.wake_key)
        time.sleep(1.5)

    print("[WARN] Глазок не вышел на связь за 180 с — проверьте, что он не ушёл в сон, нажав кнопку Home.")
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
