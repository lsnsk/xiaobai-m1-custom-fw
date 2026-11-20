#!/bin/sh
# On-device Home Screen Touch Actions (/app/eye/ui_action.sh)
# Invoked by main_app (cave6) via Home dock buttons "Snap" & "Record", or Web/TG.

. /app/eye/lib.sh
load_eye_conf
apply_tz

MODE="$1"
DUR="${2:-10}"
case "$DUR" in ''|*[!0-9]*) DUR=10 ;; esac
[ "$DUR" -lt 3 ] && DUR=3
[ "$DUR" -gt 30 ] && DUR=30

if ! mkdir /tmp/eye_ui_action.lock 2>/dev/null; then
    echo "ERR:busy"
    exit 2
fi

_had_user=0
[ -f /tmp/eye_user_active ] && _had_user=1

cleanup() {
    rmdir /tmp/eye_ui_action.lock 2>/dev/null || true
    if [ "$_had_user" -eq 0 ]; then
        rm -f /tmp/eye_user_active
        trim_awake_if_idle 15
    fi
}
trap cleanup EXIT INT TERM

rm -f /tmp/force_sleep_now
touch /tmp/eye_user_active
extend_awake 45

case "$MODE" in
    snap)
        if /app/bin/eye_snap /tmp/ui_snap.jpg "${CAM_ROTATE:-90}" 3500 && [ -s /tmp/ui_snap.jpg ]; then
            cp -f /tmp/ui_snap.jpg /tmp/web_snap.jpg 2>/dev/null || true
            rm -f /tmp/ui_snap.jpg
            _sdw=0
            while ! grep -q " /app/sd " /proc/mounts 2>/dev/null && [ "$_sdw" -lt 4 ]; do
                sleep 1
                _sdw=$((_sdw + 1))
            done
            grep -q " /app/sd " /proc/mounts 2>/dev/null || ensure_sd_mounted || true
            cache_last_snap /tmp/web_snap.jpg
            if grep -q " /app/sd " /proc/mounts 2>/dev/null; then
                mkdir -p /app/sd/snapshots
                STAMP=$(date +%Y%m%d_%H%M%S)
                cp -f /tmp/web_snap.jpg "/app/sd/snapshots/${STAMP}.jpg" 2>/dev/null || true
                sync
            fi
            send_mqtt_snapshot /tmp/web_snap.jpg "manual_snap"
            /app/eye/tg_notify.sh --manual-snap /tmp/web_snap.jpg >/dev/null 2>&1 || true
            echo "OK:/tmp/web_snap.jpg"
        else
            rm -f /tmp/ui_snap.jpg
            echo "ERR:snap_failed"
            exit 1
        fi
        ;;

    record)
        extend_awake $((DUR + 55))
        _sdw=0
        while ! grep -q " /app/sd " /proc/mounts 2>/dev/null && [ "$_sdw" -lt 10 ]; do
            sleep 1
            _sdw=$((_sdw + 1))
        done
        if ! grep -q " /app/sd " /proc/mounts 2>/dev/null; then
            ensure_sd_mounted || true
        fi
        if ! grep -q " /app/sd " /proc/mounts 2>/dev/null; then
            echo "ERR:no_sd"
            exit 1
        fi
        mkdir -p /app/sd/MIJIA_RECORD_VIDEO

        rm -f /tmp/rec_raw.jpg
        if /app/bin/eye_snap /tmp/rec_raw.jpg 0 2500 >/dev/null 2>&1 && [ -s /tmp/rec_raw.jpg ]; then
            if [ "${CAM_ROTATE:-90}" != "0" ]; then
                /app/bin/eye_tool jpgrot /tmp/rec_raw.jpg /tmp/web_snap.jpg "${CAM_ROTATE:-90}" 85 >/dev/null 2>&1 || cp -f /tmp/rec_raw.jpg /tmp/web_snap.jpg 2>/dev/null || true
            else
                cp -f /tmp/rec_raw.jpg /tmp/web_snap.jpg 2>/dev/null || true
            fi
            cache_last_snap /tmp/web_snap.jpg
        fi

        YMDH=""
        MMSS=""
        EPOCH=""
        eval "$(date '+YMDH=%Y%m%d%H MMSS=%MM%SS EPOCH=%s')"
        [ -n "$EPOCH" ] || EPOCH=$(date +%s)
        DIR="/app/sd/MIJIA_RECORD_VIDEO/${YMDH}"
        BASE="${MMSS}_${EPOCH}"
        mkdir -p "$DIR"
        MP4="${DIR}/${BASE}.mp4"
        JPG="${DIR}/${BASE}.jpeg"

        rm -f /tmp/rec_thumb.jpg
        if [ -s /tmp/rec_raw.jpg ]; then
            /app/bin/eye_tool jpgscale /tmp/rec_raw.jpg /tmp/rec_thumb.jpg 320 180 80 >/dev/null 2>&1 || rm -f /tmp/rec_thumb.jpg
            rm -f /tmp/rec_raw.jpg
        fi

        if ! /app/bin/eye_tool record "$MP4" "$DUR" || [ ! -s "$MP4" ]; then
            rm -f "${MP4}"* "${JPG}"* /tmp/rec_raw.jpg /tmp/rec_thumb.jpg
            rmdir "$DIR" 2>/dev/null || true
            echo "ERR:record_failed"
            exit 1
        fi
        if [ -s /tmp/rec_thumb.jpg ]; then
            cp -f /tmp/rec_thumb.jpg "$JPG" 2>/dev/null || true
            rm -f /tmp/rec_thumb.jpg
        fi

        /app/bin/eye_tool rlf_add /app/sd/MIJIA_RECORD_VIDEO/.record_msg "$EPOCH" "$DUR" 1 >/dev/null 2>&1 || true
        sync

        # Release action lock before Telegram/backup upload so a second snap/record is never blocked
        rmdir /tmp/eye_ui_action.lock 2>/dev/null || true
        extend_awake 55
        EYE_SYNC_NOTIFY="1" EYE_EVENT_OVERRIDE="manual" EYE_REC_DUR="$DUR" /app/bin/copy_mp4_finish.sh "$MP4" "$JPG" >/dev/null 2>&1 || true
        echo "OK:$MP4"
        ;;

    *)
        echo "Usage: $0 {snap|record [sec]}"
        exit 1
        ;;
esac
