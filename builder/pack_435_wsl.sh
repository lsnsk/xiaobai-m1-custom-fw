#!/bin/bash
set -e

VARIANT="${1:-portrait}"
case "$VARIANT" in
    portrait|landscape) ;;
    *) echo "Unknown variant: $VARIANT (expected portrait or landscape)" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_BASE="${WORK_BASE:-$HOME}"
STAGE_DIR="${SCRIPT_DIR}/out_patch_435_${VARIANT}"
ROOTFS="${WORK_BASE}/rootfs_435"
ORIG_DIR="${WORK_BASE}/rootfs_435_orig_scripts"
ORIG_PICS="${WORK_BASE}/rootfs_435_orig_pics"
export ROOTFS
mkdir -p "$ORIG_DIR" "$STAGE_DIR"

# 1. Backup untouched stock scripts & UI PNG assets once so repeated builds are 100% idempotent
if [ ! -d "$ORIG_PICS" ]; then
    cp -a "$ROOTFS/app/bin/res/pic" "$ORIG_PICS"
else
    cp -a "$ORIG_PICS/." "$ROOTFS/app/bin/res/pic/"
fi

for rel in \
    app/bootapp \
    app/bin/bootmode \
    app/bin/start_main_app.sh \
    app/bin/wifi_start.sh \
    app/bin/check_wifi.sh \
    app/bin/check_main_app.sh \
    app/bin/runlevel \
    app/bin/copy_mp4_finish.sh \
    etc/init.d/S00devs \
    etc/init.d/S30wifi \
    etc/init.d/S31loging \
    etc/profile
do
    bn=$(basename "$rel")
    if [ ! -f "$ORIG_DIR/$bn" ]; then
        cp "$ROOTFS/$rel" "$ORIG_DIR/$bn"
    else
        cp "$ORIG_DIR/$bn" "$ROOTFS/$rel"
    fi
done

# 2. Install Russian language packs, Cyrillic fonts, Russian sounds (/app/sound -> /tmp/sound), portrait higv.bin, patched main_app & eye_tool
cp "${SCRIPT_DIR}/out_patch/zh.lang" "$ROOTFS/app/bin/zh.lang"
cp "${SCRIPT_DIR}/out_patch/en.lang" "$ROOTFS/app/bin/en.lang"
cp "${SCRIPT_DIR}/out_patch/res/font/"*.ubf "$ROOTFS/app/bin/res/font/"
if [ -d "$ROOTFS/app/sound" ] && [ ! -L "$ROOTFS/app/sound" ]; then
    rm -rf "$ROOTFS/app/sound_rom"
    mv "$ROOTFS/app/sound" "$ROOTFS/app/sound_rom"
    ln -sfn /tmp/sound "$ROOTFS/app/sound"
fi
for f in 01_fastreply 02_fastreply 03_fastreply 04_fastreply 5GHz_wifi_supported binding_fail binding_success booting connecting_pease_wait error qrcode_success qrcode_supported reset_success waiting_connection wifi_connected; do
    cp "${SCRIPT_DIR}/out_patch/sound/$f" "$ROOTFS/app/sound_rom/$f"
    chmod 755 "$ROOTFS/app/sound_rom/$f"
done

cp "$STAGE_DIR/main_app" "$ROOTFS/app/bin/main_app"
cp "$STAGE_DIR/higv.bin" "$ROOTFS/app/bin/higv.bin"
cp "${SCRIPT_DIR}/out_patch_435/eye_tool" "$ROOTFS/app/bin/eye_tool"
cp "${SCRIPT_DIR}/out_patch_435/eye_snap" "$ROOTFS/app/bin/eye_snap"
chmod 755 "$ROOTFS/app/bin/eye_snap"
# Stock /etc/profile runs `hwclock -s` after exporting TZ from /tmp/TZ -> keep HW RTC in local wall-clock time matching LiteOS /dev/hi_rtc
sed -i 's/^hwclock -s\r\?$/hwclock -s -l/' "$ROOTFS/etc/profile"
cp "$STAGE_DIR/res_pic/"*.png "$ROOTFS/app/bin/res/pic/"
chmod 755 "$ROOTFS/app/bin/main_app" "$ROOTFS/app/bin/eye_tool" "$ROOTFS/app/bin/zh.lang" "$ROOTFS/app/bin/en.lang"
chmod 644 "$ROOTFS/app/bin/higv.bin" "$ROOTFS/app/bin/res/pic/"*.png

# 3. Install autonomous addon suite (/app/eye) & dynamic symlinks
rm -rf "$ROOTFS/app/eye"
mkdir -p "$ROOTFS/app/eye/www/cgi-bin"
cp -r "${SCRIPT_DIR}/eye_addon/"* "$ROOTFS/app/eye/"
cp "$STAGE_DIR/eye.conf.example" "$ROOTFS/app/eye/eye.conf.example"
if [ "$VARIANT" = "landscape" ]; then
    sed -i 's/^UI_ORIENT=.*/UI_ORIENT="landscape"/; s/^CAM_ROTATE=.*/CAM_ROTATE=0/; s/^VO_ROTATE=.*/VO_ROTATE=90/' "$ROOTFS/app/eye/eye.conf.default"
else
    sed -i 's/^UI_ORIENT=.*/UI_ORIENT="portrait"/; s/^CAM_ROTATE=.*/CAM_ROTATE=90/; s/^VO_ROTATE=.*/VO_ROTATE=90/' "$ROOTFS/app/eye/eye.conf.default"
fi

find "$ROOTFS/app/eye" -type f -exec sed -i 's/\r$//' {} +
chmod 755 "$ROOTFS/app/eye/"*.sh "$ROOTFS/app/eye/www/cgi-bin/"*.cgi
chmod 644 "$ROOTFS/app/eye/eye.conf.default" "$ROOTFS/app/eye/eye.conf.example" "$ROOTFS/app/eye/www/index.html"

ln -sfn /app/sd/MIJIA_RECORD_VIDEO "$ROOTFS/app/eye/www/sd"
ln -sfn /app/sd/snapshots "$ROOTFS/app/eye/www/snapshots"
ln -sfn /tmp/web_snap.jpg "$ROOTFS/app/eye/www/live.jpg"
rm -f "$ROOTFS/etc/TZ" "$ROOTFS/etc/os-release"
ln -sfn /tmp/TZ "$ROOTFS/etc/TZ"
ln -sfn /tmp/os-release "$ROOTFS/etc/os-release"

# 4. Patch boot, Wi-Fi, cloud-toggle & media rotation hooks
python3 - << 'PYEOF'
import os
ROOT = os.environ["ROOTFS"]

# 4a. /app/bootapp: keep persistent telnetd + SD testmode hook
p_boot = f"{ROOT}/app/bootapp"
s = open(p_boot, "r").read().replace("\r\n", "\n")
marker = "echo 1024 > /proc/sys/vm/user_reserve_kbytes"
hook = marker + """

	mkdir -p /dev/pts
	mount -t devpts devpts /dev/pts 2>/dev/null
	telnetd &
	if [ -f /mnt/sdcard/IPC018_TESTMODE.file ] || [ -f /app/sd/IPC018_TESTMODE.file ]; then
		/app/bin/factory set test 1
		cd /app/komod && ./load_module && ./usb2net_load.sh
		ifconfig usb0 192.168.0.1 netmask 255.255.255.0
	fi"""
if "if [ -f /mnt/sdcard/IPC018_TESTMODE.file ]" not in s:
    s = s.replace(marker, hook, 1)
open(p_boot, "w", newline="\n").write(s)

# 4b. /etc/init.d/S00devs: early /tmp/TZ, /tmp/os-release, /tmp/sound overlay, SD testmode + telnetd + eye_early_init.sh
p_s00 = f"{ROOT}/etc/init.d/S00devs"
s0 = open(p_s00, "r").read().replace("\r\n", "\n")
if 'echo "MSK-3" > /tmp/TZ' not in s0:
    s0 = s0.replace("mount tmpfs /tmp -t tmpfs", 'mount tmpfs /tmp -t tmpfs\necho "MSK-3" > /tmp/TZ', 1)
if 'echo "CHUANGMI_VERSION=4.3.5_3319" > /tmp/os-release' not in s0:
    s0 = s0.replace('echo "MSK-3" > /tmp/TZ', 'echo "MSK-3" > /tmp/TZ\necho "CHUANGMI_VERSION=4.3.5_3319" > /tmp/os-release', 1)
if "mkdir -p /tmp/sound" not in s0:
    s0 = s0.replace("mount tmpfs /tmp -t tmpfs", "mount tmpfs /tmp -t tmpfs\nmkdir -p /tmp/sound && ln -sf /app/sound_rom/* /tmp/sound/ 2>/dev/null", 1)
old_pre_check = """/sbin/mdev -s
mount -t vfat /dev/mmcblk0p1 /app/sd 2>/dev/null
if [ -f /app/sd/IPC018_TESTMODE.file ]; then
    /app/bin/factory set test 1
fi
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null
telnetd &
testvar=$(/app/bin/factory get test)"""
if old_pre_check in s0:
    s0 = s0.replace(old_pre_check, "testvar=$(/app/bin/factory get test)", 1)

pre_check_v1 = """/sbin/mdev -s
mount -t vfat -o ro /dev/mmcblk0p1 /app/sd 2>/dev/null
if [ -f /app/sd/IPC018_TESTMODE.file ]; then
    /app/bin/factory set test 1
fi
umount /app/sd 2>/dev/null
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null
telnetd &
testvar=$(/app/bin/factory get test)"""
if pre_check_v1 in s0:
    s0 = s0.replace(pre_check_v1, "testvar=$(/app/bin/factory get test)", 1)

pre_check = r"""/sbin/mdev -s
mount -t vfat -o ro /dev/mmcblk0p1 /app/sd 2>/dev/null
if [ -f /app/sd/IPC018_TESTMODE.file ]; then
    /app/bin/factory set test 1
elif [ -f /app/sd/IPC018_NORMAL.file ]; then
    /app/bin/factory set test 0
fi
if [ -f /app/sd/IPC018_UPDATE.file ] && [ -f /app/sd/patch_435/rootfs.squashfs ] && [ -f /app/sd/patch_435/MD5SUMS.txt ]; then
    umount /app/sd 2>/dev/null
    if mount -t vfat /dev/mmcblk0p1 /app/sd 2>/dev/null; then
        rm -f /app/sd/IPC018_UPDATE.file /app/sd/IPC018_NORMAL.file /app/sd/IPC018_TESTMODE.file
        sync
        SPEC7=$(tr -d '\r' < /app/sd/patch_435/MD5SUMS.txt | awk '$2=="rootfs.squashfs"{print $1}')
        ACT7=$(md5sum /app/sd/patch_435/rootfs.squashfs | awk '{print $1}')
        SZ7=$(wc -c < /app/sd/patch_435/rootfs.squashfs 2>/dev/null | tr -cd '0-9')
        if [ -n "$SPEC7" ] && [ "$SPEC7" = "$ACT7" ] && [ "${SZ7:-0}" -gt 0 ] && [ "${SZ7:-0}" -le 8388608 ]; then
            echo "====== SD Update mtd7 ======"
            mkdir -p /tmp/lib
            cp -a /lib/* /tmp/lib/ 2>/dev/null || true
            cp /bin/busybox /tmp/busybox && cp /app/bin/upmtd /tmp/upmtd && cp /app/bin/factory /tmp/factory
            chmod 755 /tmp/busybox /tmp/upmtd /tmp/factory
            LD_LIBRARY_PATH=/tmp/lib:/app/lib /tmp/factory set test 0
            if LD_LIBRARY_PATH=/tmp/lib /tmp/upmtd /app/sd/patch_435/rootfs.squashfs /dev/mtd7; then
                LD_LIBRARY_PATH=/tmp/lib /tmp/busybox sync
                LD_LIBRARY_PATH=/tmp/lib /tmp/busybox umount /app/sd 2>/dev/null || true
                LD_LIBRARY_PATH=/tmp/lib /tmp/busybox reboot -f
            fi
        fi
    fi
fi
umount /app/sd 2>/dev/null
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null
telnetd &
testvar=$(/app/bin/factory get test)"""
if "IPC018_UPDATE.file" not in s0:
    s0 = s0.replace("testvar=$(/app/bin/factory get test)", pre_check, 1)
if 'echo "====== Test Mode ======"\n    mount -t vfat /dev/mmcblk0p1 /app/sd 2>/dev/null' not in s0:
    s0 = s0.replace('    echo "====== Test Mode ======"', '    echo "====== Test Mode ======"\n    mount -t vfat /dev/mmcblk0p1 /app/sd 2>/dev/null', 1)
if "/app/eye/eye_early_init.sh" not in s0:
    s0 = s0.replace("    /app/bin/wifi_start.sh", "    /app/eye/eye_early_init.sh\n    /app/bin/wifi_start.sh", 1)
open(p_s00, "w", newline="\n").write(s0)

# 4b1. /etc/init.d/S31loging: remove stray factory SD mount & 2s sleep that raced main_app STG_FSTOOL_Mount
p_s31 = f"{ROOT}/etc/init.d/S31loging"
s31 = open(p_s31, "r").read().replace("\r\n", "\n")
s31 = s31.replace("\tmount /dev/mmcblk0p1 /mnt/sdcard\n\tsleep 2\n", "")
open(p_s31, "w", newline="\n").write(s31)

# 4b2. /etc/profile: fix stock TZ='Asia/Shanghai' (broken in uClibc without zoneinfo) to read /tmp/TZ
p_prof = f"{ROOT}/etc/profile"
sp = open(p_prof, "r").read().replace("\r\n", "\n")
sp = sp.replace("TZ='Asia/Shanghai'\nexport TZ", 'TZ=$(cat /tmp/TZ 2>/dev/null || echo "MSK-3")\nexport TZ')
open(p_prof, "w", newline="\n").write(sp)

# 4b3. /app/bin/bootmode (VA 0x11874 -> file 0x1874) & /etc/init.d/S30wifi:
#      Stock bootmode skips start_main_app.sh on doorbell wakeups (0x86d8000c == 1) and spins forever on
#      connect(127.0.0.1:54322) when MI_CLOUD_ENABLE=0, leaving LiteOS video frozen with no UI buttons until MCU resets.
#      Patch bootmode branch 0x1874 (beq 0x118a0 -> nop) so cloud mode also starts main_app immediately,
#      and bypass bootmode in S30wifi when MI_CLOUD_ENABLE!=1.
p_bm = f"{ROOT}/app/bin/bootmode"
bm_data = bytearray(open(p_bm, "rb").read())
bm_cur = bytes(bm_data[0x1874:0x1878])
assert bm_cur in (b"\x09\x00\x00\x0a", b"\x00\x00\xa0\xe1"), f"Unexpected bootmode insn at 0x1874: {bm_cur.hex()}"
bm_data[0x1874:0x1878] = b"\x00\x00\xa0\xe1"
open(p_bm, "wb").write(bm_data)

p_s30 = f"{ROOT}/etc/init.d/S30wifi"
s30 = open(p_s30, "r").read().replace("\r\n", "\n")
old_s30_bm = "      /app/bin/bootmode -l 2 &\n"
new_s30_bm = """      . /app/eye/lib.sh
      load_eye_conf
      if [ "${MI_CLOUD_ENABLE:-0}" = "1" ]; then
          /app/bin/bootmode -l 2 &
      else
          /app/bin/start_main_app.sh &
      fi
"""
assert old_s30_bm in s30, "Expected bootmode launch line in S30wifi"
s30 = s30.replace(old_s30_bm, new_s30_bm, 1)
open(p_s30, "w", newline="\n").write(s30)

# 4c. /app/bin/start_main_app.sh: run eye_early_init.sh before ./main_app, log events to /tmp/main_app.log & ensure offline watchdogs (no miio_stream when MI_CLOUD_ENABLE=0!)
p_sma = f"{ROOT}/app/bin/start_main_app.sh"
sma = open(p_sma, "r").read().replace("\r\n", "\n")
sma = sma.replace(
    "cd /app/bin\n",
    "/app/eye/eye_early_init.sh\n. /app/eye/lib.sh\nload_eye_conf\ncd /app/bin\n",
    1,
)
sma = sma.replace(
    "    ./main_app &\n",
    "    ./main_app >> /tmp/main_app.log 2>&1 &\n",
    1,
)
offline_tail = """
if [ "${MI_CLOUD_ENABLE:-0}" != "1" ]; then
    check_main_app_result=`/bin/ps | grep check_main_app.sh | grep -v grep`
    if [ -z "$check_main_app_result" ]; then
        /app/bin/check_main_app.sh &
    fi
fi
"""
sma = sma + offline_tail
open(p_sma, "w", newline="\n").write(sma)

# 4d. /app/bin/wifi_start.sh: autonomous STA connect, open-Wi-Fi support, MI_CLOUD_ENABLE toggle (no TUTK miio_stream when 0!) & eye_post_wifi.sh
p_ws = f"{ROOT}/app/bin/wifi_start.sh"
ws = open(p_ws, "r").read().replace("\r\n", "\n")
ws = ws.replace("#!/bin/sh\n", "#!/bin/sh\n. /app/eye/lib.sh\nload_eye_conf\n", 1)
ws = ws.replace(
    "/app/bin/cw connect -S $base64_ssid -k $passwd",
    'echo "setfilter -c" > /proc/cywdhd 2>/dev/null || true; if [ -z "$passwd" ]; then /app/bin/cw connect -S "$base64_ssid"; else /app/bin/cw connect -S "$base64_ssid" -k "$passwd"; fi',
)
ws = ws.replace(
    "\tnice -n -20 /app/bin/miio_stream &",
    '\tif [ "${MI_CLOUD_ENABLE:-0}" = "1" ]; then\n\t\tnice -n -20 /app/bin/miio_stream &\n\tfi',
    1,
)
ws = ws.replace(
    """start_process()
{
\tclient_result=`ps | grep miio_client |awk 'NR==1{print $4}'`
\tif [ x"$client_result" != x"miio_client" ]; then
\t\t/app/bin/miio_client -l 2 -d /tmp/ -o DISABLE_PSM -L /var/log/miio_client.log &
\t\t/app/bin/miio_client_helper_nomqtt.sh &
\tfi

}""",
    """start_process()
{
\tif [ "${MI_CLOUD_ENABLE:-0}" = "1" ]; then
\t\tclient_result=`ps | grep miio_client | grep -v grep | awk 'NR==1{print $4}'`
\t\tif [ -z "$client_result" ]; then
\t\t\t/app/bin/miio_client -l 2 -d /tmp/ -o DISABLE_PSM -L /var/log/miio_client.log &
\t\t\t/app/bin/miio_client_helper_nomqtt.sh &
\t\tfi
\tfi
\t/app/eye/eye_post_wifi.sh >/dev/null 2>&1 &
}""",
)
ws = ws.replace(
    '    wifi_ready=`/app/bin/recovery_wifi bind_status`',
    '    wifi_ready=`/app/bin/recovery_wifi bind_status`\n    if [ x"$wifi_ready" != x"ok" ]; then\n        wifi_ready=`mortoxc get nvram default bind_status`\n    fi',
)
ws = ws.replace(
    "    wifi_ap_mode $MAC $macstring",
    '    if [ "${MI_CLOUD_ENABLE:-0}" = "1" ]; then\n        wifi_ap_mode $MAC $macstring\n    fi',
)
open(p_ws, "w", newline="\n").write(ws)

# 4e. /app/bin/check_wifi.sh: bounded reconnect backoff + safe hardware sleep release when router unreachable
p_cw = f"{ROOT}/app/bin/check_wifi.sh"
open(p_cw, "w", newline="\n").write("""#!/bin/sh
. /app/eye/lib.sh
load_eye_conf

INTERVAL=15
STATUS=0
COUNT=0
FAILS=0
MAX_FAILS=1
interface=wlan0
macstring=`factory get mac`

interval() {
    sleep $INTERVAL
    COUNT=$(expr $COUNT + $INTERVAL)
}

checkping() {
    load_eye_conf
    if [ -z "$(get_wlan_ip)" ]; then
        STATUS=1
        return
    fi
    TARGET="$PING_HOST"
    if [ -z "$TARGET" ]; then
        TARGET=`route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $2; exit}'`
    fi
    if [ -n "$TARGET" ] && ping -c 1 -W 3 -w 3 "$TARGET" > /dev/null 2>&1; then
        FAILS=0
        INTERVAL=20
        STATUS=0
    else
        STATUS=1
    fi
}

do_recovery_wifi() {
    if [ "$STATUS" = "1" ]; then
        FAILS=$((FAILS + 1))
        if [ "$FAILS" -gt "$MAX_FAILS" ]; then
            release_awake_now
            INTERVAL=120
            STATUS=0
            return 0
        fi
        key_mgmt=`mortoxc get nvram default key_mgmt`
        if [ "$key_mgmt" = "NONE" ]; then
            passwd=""
        else
            passwd=`mortoxc get nvram default miio_passwd`
        fi
        ssid=`mortoxc get nvram default miio_ssid`
        if [ -z "$ssid" ]; then
            INTERVAL=120
            STATUS=0
            return 0
        fi

        killall -9 dhcpc_ex udhcpc wpa_supplicant hostapd udhcpd 2>/dev/null
        ifconfig $interface up
        ifconfig $interface hw ether $macstring
        echo "setfilter -c" > /proc/cywdhd 2>/dev/null || true
        base64_ssid=`/app/bin/b64e "$ssid"`
        if [ -z "$passwd" ]; then
            /app/bin/cw connect -S "$base64_ssid"
        else
            /app/bin/cw connect -S "$base64_ssid" -k "$passwd"
        fi
        /app/bin/dhcpc_ex &
        /app/eye/eye_post_wifi.sh >/dev/null 2>&1 &
        STATUS=0
        INTERVAL=$((15 * FAILS))
    fi
}

while :; do
    interval
    bind_status=`mortoxc get nvram default bind_status`
    ssid_now=`mortoxc get nvram default miio_ssid`
    if [ x"$bind_status" = x"ok" ] && [ -n "$ssid_now" ]; then
        checkping
        do_recovery_wifi
    fi

    if [ "$COUNT" -ge 60 ]; then
        COUNT=0
        if [ "${MI_CLOUD_ENABLE:-0}" = "1" ] && [ ! -d "/tmp/miio_log" ]; then
            mkdir /tmp/miio_log
            /app/bin/miio_log
            rm -rf /tmp/miio_log
        fi
    fi
done
""")

# 4f. /app/bin/check_main_app.sh: fix stock typo & guard miio_client + miio_stream with MI_CLOUD_ENABLE=1
p_cm = f"{ROOT}/app/bin/check_main_app.sh"
open(p_cm, "w", newline="\n").write("""#!/bin/sh
. /app/eye/lib.sh
load_eye_conf

INTERVAL=15
COUNT=0
cd /app/bin

while :; do
    sleep $INTERVAL
    COUNT=$(expr $COUNT + $INTERVAL)
    if [ "$COUNT" -ge 30 ]; then
        COUNT=0
        load_eye_conf
        if [ "${MI_CLOUD_ENABLE:-0}" = "1" ]; then
            if ! ps | grep -v grep | grep -q '/app/bin/miio_client'; then
                /app/bin/miio_client -l 2 -d /tmp/ -o DISABLE_PSM -L /var/log/miio_client.log &
            fi
            if ! ps | grep -v grep | grep -q '/app/bin/miio_stream'; then
                nice -n -20 /app/bin/miio_stream &
            fi
            if ! ps | grep -v grep | grep -q '/app/bin/bootmode'; then
                /app/bin/bootmode -l 2 &
            fi
        else
            if ! pidof main_app >/dev/null 2>&1; then
                /app/bin/start_main_app.sh &
            fi
        fi
        if [ -f /tmp/main_app.log ] && [ "$(wc -c < /tmp/main_app.log 2>/dev/null || echo 0)" -gt 32768 ]; then
            detect_event_type >/dev/null 2>&1 || true
            get_battery_mv >/dev/null 2>&1 || true
            : > /tmp/main_app.log
        fi
    fi
done
""")

# 4g. /app/bin/runlevel: force normal SD-recording services when MI_CLOUD_ENABLE=0 & skip miio_ota
p_rl = f"{ROOT}/app/bin/runlevel"
open(p_rl, "w", newline="\n").write("""#!/bin/sh
. /app/eye/lib.sh
load_eye_conf

perpctl A mortox >/dev/null 2>&1

probe() {
    if [ "${MI_CLOUD_ENABLE:-0}" != "1" ]; then
        echo "normal"
        return
    fi
    status=$(mortoxc get nvram default bind_status)
    case "$status" in
        ok) echo "normal" ;;
        *)  echo "init" ;;
    esac
}

get_rl() {
    mortoxc get mem default runlevel
}

set_rl() {
    rl=$1
    echo "Entering service runlevel $rl"
    cd /etc/services.d/$1 || return
    mortoxc set mem default runlevel "$rl"
    for s in K*; do
        [ -e "$s" ] && perpctl X ${s:1}
    done
    for s in S*; do
        [ -e "$s" ] || continue
        svc="${s:1}"
        if [ "${MI_CLOUD_ENABLE:-0}" != "1" ]; then
            case "$svc" in
                miio_ota|miio_client|miio_client_helper|miio_qrcode)
                    perpctl X "$svc" 2>/dev/null || true
                    continue
                    ;;
            esac
        fi
        perpctl A "$svc"
    done
}

while getopts "hps:" arg; do
    case $arg in
        p) probe; exit ;;
        s) set_rl "$OPTARG"; exit ;;
        h) exit ;;
    esac
done

get_rl
""")

# 4h. /app/bin/copy_mp4_finish.sh: rotate .jpeg & .mp4 to vertical 9:16, backup via FTP/WebDAV, fire HA webhook + MQTT & notify Telegram
p_cp = f"{ROOT}/app/bin/copy_mp4_finish.sh"
open(p_cp, "w", newline="\n").write("""#!/bin/sh
. /app/eye/lib.sh
load_eye_conf

MP4_FILE="$1"
echo "copy mp4 to tf finish: $MP4_FILE"

if [ -n "$MP4_FILE" ] && [ -f "$MP4_FILE" ]; then
    JPG_FILE="${MP4_FILE%.mp4}.jpeg"
    ROT="${CAM_ROTATE:-90}"
    if [ "$ROT" != "0" ]; then
        if [ -f "$JPG_FILE" ]; then
            /app/bin/eye_tool jpgrot "$JPG_FILE" "$JPG_FILE" "$ROT" 85 || true
        fi
        /app/bin/eye_tool mp4rot "$MP4_FILE" "$ROT" || true
    fi
    sync
    _ev="${EYE_EVENT_OVERRIDE:-$(detect_event_type)}"
    upload_net_backup "$MP4_FILE" "$JPG_FILE" "$_ev"
    send_ha_webhook "$_ev" "${MP4_FILE#/app/sd/MIJIA_RECORD_VIDEO/}"
    _mqtt_jpg=""
    if [ "$_ev" = "manual" ]; then
        _mqtt_jpg=$(get_mqtt_fallback_snap || true)
        [ -n "$_mqtt_jpg" ] && [ -s "$_mqtt_jpg" ] || _mqtt_jpg="$JPG_FILE"
    elif [ -f /tmp/eye_boot_alarm_sent ] && [ -s /tmp/tg_alarm.jpg ]; then
        cache_last_snap /tmp/tg_alarm.jpg
        _mqtt_jpg=""
    elif [ -s /tmp/tg_alarm.jpg ]; then
        cache_last_snap /tmp/tg_alarm.jpg
        _mqtt_jpg="/tmp/tg_alarm.jpg"
    elif [ -s /dev/alarm0.jpeg ]; then
        if [ "$ROT" != "0" ]; then
            /app/bin/eye_tool jpgrot /dev/alarm0.jpeg /tmp/tg_alarm.jpg "$ROT" 85 >/dev/null 2>&1 || cp -f /dev/alarm0.jpeg /tmp/tg_alarm.jpg 2>/dev/null || true
        else
            cp -f /dev/alarm0.jpeg /tmp/tg_alarm.jpg 2>/dev/null || true
        fi
        cache_last_snap /tmp/tg_alarm.jpg
        _mqtt_jpg="/tmp/tg_alarm.jpg"
    else
        _mqtt_jpg="$JPG_FILE"
    fi
    send_mqtt_event "$_ev" "${MP4_FILE#/app/sd/MIJIA_RECORD_VIDEO/}" "$_mqtt_jpg"
    if [ "${EYE_SYNC_NOTIFY:-0}" = "1" ]; then
        EYE_EVENT_OVERRIDE="$_ev" EYE_REC_DUR="${EYE_REC_DUR:-}" /app/eye/tg_notify.sh --clip "$MP4_FILE" "$JPG_FILE" >/dev/null 2>&1 || true
    else
        EYE_EVENT_OVERRIDE="$_ev" EYE_REC_DUR="${EYE_REC_DUR:-}" /app/eye/tg_notify.sh --clip "$MP4_FILE" "$JPG_FILE" >/dev/null 2>&1 &
    fi
fi
""")

print("Successfully patched all rootfs_435 startup, Wi-Fi, cloud-toggle & rotation hooks!")
PYEOF

chmod 755 \
    "$ROOTFS/app/bootapp" \
    "$ROOTFS/etc/init.d/S00devs" \
    "$ROOTFS/etc/init.d/S30wifi" \
    "$ROOTFS/app/bin/bootmode" \
    "$ROOTFS/app/bin/start_main_app.sh" \
    "$ROOTFS/app/bin/wifi_start.sh" \
    "$ROOTFS/app/bin/check_wifi.sh" \
    "$ROOTFS/app/bin/check_main_app.sh" \
    "$ROOTFS/app/bin/runlevel" \
    "$ROOTFS/app/bin/copy_mp4_finish.sh"

# 5. Pack SquashFS image (XZ, 128 KiB block size, root-owned, <= 8.00 MB)
rm -f "$STAGE_DIR/rootfs.squashfs"
mksquashfs "$ROOTFS" "$STAGE_DIR/rootfs.squashfs" -comp xz -b 131072 -all-root -no-xattrs -noappend
ls -la "$STAGE_DIR/rootfs.squashfs"
