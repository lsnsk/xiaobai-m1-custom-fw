#!/bin/sh
# Early boot hook: runs before wifi_start.sh and before main_app starts.
# Briefly mounts SD only long enough to cache /tmp/eye.conf.clean & copy custom voices into RAM,
# then unmounts /app/sd so main_app's STG_FSTOOL_Mount gets clean exclusive ownership of /dev/mmcblk0p1.

. /app/eye/lib.sh

_test_mode=$(/app/bin/factory get test 2>/dev/null)
_main_pid=$(pidof main_app 2>/dev/null)

_need_sd=0
if [ ! -f /tmp/eye_sd_cached ] || [ ! -f /tmp/eye_guard_done ]; then
    _need_sd=1
    if ! grep -q ' /app/sd ' /proc/mounts 2>/dev/null; then
        if [ -b /dev/mmcblk0p1 ]; then
            mount -t vfat /dev/mmcblk0p1 /app/sd 2>/dev/null || true
        elif [ -b /dev/mmcblk0 ]; then
            mount -t vfat /dev/mmcblk0 /app/sd 2>/dev/null || true
        fi
    fi
fi

if [ ! -f /tmp/eye_sd_cached ]; then
    if grep -q ' /app/sd ' /proc/mounts 2>/dev/null; then
        if [ ! -f /app/sd/eye.conf ] && [ ! -f /app/sd/eye.conf.example ] && [ -f /app/eye/eye.conf.example ]; then
            cp /app/eye/eye.conf.example /app/sd/eye.conf.example 2>/dev/null || true
            sync
        fi
        load_eye_conf
        sync_custom_voices
        if [ -f /app/sd/.eye_bat_cache ]; then
            cp -f /app/sd/.eye_bat_cache /tmp/eye_bat_cache 2>/dev/null || true
        fi
        _early_sd=$(df -h /app/sd 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')
        if [ -n "$_early_sd" ]; then
            _cbat=$(read_bat_cache "CACHED_BAT" 2>/dev/null || true)
            _cmv=$(read_bat_cache "CACHED_MV" 2>/dev/null || true)
            printf "CACHED_BAT=%s\nCACHED_MV=%s\nCACHED_SD=%s\n" "$_cbat" "$_cmv" "$_early_sd" > /tmp/eye_bat_cache 2>/dev/null || true
        fi
        touch /tmp/eye_sd_cached
    else
        load_eye_conf
        sync_custom_voices
    fi
else
    load_eye_conf
fi

apply_tz
if [ ! -f /tmp/eye_rtc_synced ]; then
    TZ="${TZ:-MSK-3}" hwclock -s -l >/dev/null 2>&1 || true
    touch /tmp/eye_rtc_synced
fi
apply_vo_rotate

# --- Reboot-loop guard: if main_app keeps crashing, alarm0.jpeg triggers infinite restart ---
# Runs once per boot (S00devs) reusing the single early /app/sd mount before umounting for main_app.
if [ ! -f /tmp/eye_guard_done ]; then
    touch /tmp/eye_guard_done
    if grep -q ' /app/sd ' /proc/mounts 2>/dev/null; then
        _now=$(date +%s 2>/dev/null || echo 0)
        _prev_ts=$(cat /app/sd/.eye_boot_ts 2>/dev/null || echo 0)
        _cnt=$(cat /app/sd/.eye_crash_cnt 2>/dev/null || echo 0)
        case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
        case "$_prev_ts" in ''|*[!0-9]*) _prev_ts=0 ;; esac
        case "$_cnt" in ''|*[!0-9]*) _cnt=0 ;; esac
        _age=$(( _now - _prev_ts ))
        if [ -f /app/sd/.eye_unclean_boot ] && [ "$_age" -ge 0 ] 2>/dev/null && [ "$_age" -lt 45 ] 2>/dev/null; then
            _cnt=$(( _cnt + 1 ))
            # --- Save crash log to SD (only on crash, not on normal boot) ---
            _clog_dir=/app/sd/.eye_crashlogs
            mkdir -p "$_clog_dir" 2>/dev/null || true
            _clog="$_clog_dir/crash_$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo $_now)_cnt${_cnt}.txt"
            {
                echo "=== EYE CRASH LOG ==="
                echo "time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) uptime_prev=${_prev_ts} age=${_age}s cnt=${_cnt}"
                echo "--- /proc/uptime ---"
                cat /proc/uptime 2>/dev/null
                echo "--- /dev/alarm*.jpeg presence ---"
                ls -la /dev/alarm*.jpeg 2>/dev/null || echo "(none)"
                echo "--- dmesg (tail 60) ---"
                dmesg 2>/dev/null | tail -60
                echo "--- logread (tail 80) ---"
                logread 2>/dev/null | tail -80
                echo "--- /tmp/eye_*.log ---"
                for _lf in /tmp/eye_*.log; do
                    [ -f "$_lf" ] || continue
                    echo ">> $_lf:"
                    tail -30 "$_lf" 2>/dev/null
                done
                echo "=== END ==="
            } > "$_clog" 2>/dev/null
            # Rotate: keep last 10 crash logs only
            ls -t "$_clog_dir"/crash_*.txt 2>/dev/null | tail -n +11 | while read _old; do rm -f "$_old"; done
            logger -t eye_guard "Crash log saved: $_clog (cnt=$_cnt)"
            # --- end crash log ---
        else
            _cnt=0
        fi
        echo "$_now" > /app/sd/.eye_boot_ts 2>/dev/null || true
        echo "$_cnt" > /app/sd/.eye_crash_cnt 2>/dev/null || true
        echo 1 > /app/sd/.eye_unclean_boot 2>/dev/null || true
        if [ "$_cnt" -ge 3 ]; then
            # Crash loop detected: clear alarm trigger and reset counter
            rm -f /dev/alarm0.jpeg /dev/alarm1.jpeg 2>/dev/null || true
            echo 0 > /app/sd/.eye_crash_cnt 2>/dev/null || true
            logger -t eye_guard "CRASH LOOP detected (cnt=$_cnt) — cleared alarm*.jpeg"
        fi
        sync
    fi
fi
# --- end reboot-loop guard ---

if [ "$_test_mode" != "1" ] && [ -z "$_main_pid" ]; then
    if grep -q ' /app/sd ' /proc/mounts 2>/dev/null; then
        umount /app/sd 2>/dev/null || umount -l /app/sd 2>/dev/null || true
    fi
fi

write_os_release

# Signal main_app sleep_hook whether Xiaomi Cloud / TUTK is disabled (prevents 60s/30min offline sleep stalls)
if [ "${MI_CLOUD_ENABLE:-0}" = "1" ]; then
    rm -f /tmp/no_cloud
else
    touch /tmp/no_cloud
fi

# Wait briefly for mortoxd IPC socket
_i=0
while [ $_i -lt 15 ]; do
    if mortoxc get nvram default bind_status >/dev/null 2>&1; then
        break
    fi
    usleep 100000 2>/dev/null || sleep 1
    _i=$((_i + 1))
done

if [ "${MI_CLOUD_ENABLE:-0}" != "1" ]; then
    mortoxc set mem default net_status 1 >/dev/null 2>&1 || true
    mortoxc set mem default tutk_key 0 >/dev/null 2>&1 || true
    if ! ps | grep -v grep | grep -q '/app/eye/eye_daemon.sh'; then
        /app/eye/eye_daemon.sh >/dev/null 2>&1 &
    fi
    if [ ! -f /tmp/force_sleep_now ]; then
        extend_awake 20
    fi
fi

_nv_dirty=0

if [ -n "$WIFI_SSID" ]; then
    _cur_ssid=$(mortoxc get nvram default miio_ssid 2>/dev/null | tr -d '\r\n')
    _cur_pass=$(mortoxc get nvram default miio_passwd 2>/dev/null | tr -d '\r\n')
    _cur_bind=$(mortoxc get nvram default bind_status 2>/dev/null | tr -d '\r\n')
    _want_mgmt="WPA-PSK"
    [ -z "$WIFI_PASS" ] && _want_mgmt="NONE"

    if [ "$_cur_ssid" != "$WIFI_SSID" ] || [ "$_cur_pass" != "$WIFI_PASS" ] || [ "$_cur_bind" != "ok" ]; then
        mortoxc set nvram default miio_ssid "$WIFI_SSID" >/dev/null 2>&1
        mortoxc set nvram default miio_passwd "$WIFI_PASS" >/dev/null 2>&1
        mortoxc set nvram default key_mgmt "$_want_mgmt" >/dev/null 2>&1
        mortoxc set nvram default bind_status "ok" >/dev/null 2>&1
        touch /tmp/eye_force_dhcp
        _nv_dirty=1
    fi
fi

sync_opt_nv() {
    _nv_k="$1"
    _nv_v="$2"
    [ -n "$_nv_v" ] || return 0
    _cur_v=$(mortoxc get nvram default "$_nv_k" 2>/dev/null | tr -d '\r\n')
    if [ "$_cur_v" != "$_nv_v" ]; then
        mortoxc set nvram default "$_nv_k" "$_nv_v" >/dev/null 2>&1
        mortoxc set mem default "$_nv_k" "$_nv_v" >/dev/null 2>&1
        _nv_dirty=1
    fi
}

sync_opt_nv "s_alarmSwitch"          "$PIR_ENABLE"
sync_opt_nv "s_stayTime"             "$PIR_STAY_SEC"
sync_opt_nv "s_videoInterval"        "$PIR_INTERVAL_SEC"
sync_opt_nv "s_brightScreen"         "$RING_SCREEN_ON"
sync_opt_nv "s_night"                "$NIGHT_MODE"
sync_opt_nv "s_wdr"                  "$WDR_ENABLE"
sync_opt_nv "s_distortionCorrection" "$LDC_ENABLE"
sync_opt_nv "s_lowBattery"           "$LOW_BAT_ALERT"

apply_dnd_ram

if [ "$_nv_dirty" -eq 1 ]; then
    /app/bin/backnv.sh >/dev/null 2>&1 &
fi
