#!/bin/sh
# Post-Wi-Fi hook: ensures DHCP/recovery IP cache, WoWLAN, NTP, Web UI, UDP listener,
# exact event detection, DND-aware smart auto-reply, MQTT / Home Assistant / ntfy hooks & low-battery alert.

. /app/eye/lib.sh
load_eye_conf

if [ -f /var/run/eye_post_wifi.lock ]; then
    _old=$(cat /var/run/eye_post_wifi.lock 2>/dev/null)
    if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > /var/run/eye_post_wifi.lock

if ! ps | grep -v grep | grep -q '/app/eye/eye_daemon.sh'; then
    /app/eye/eye_daemon.sh >/dev/null 2>&1 &
fi

# Smart Auto Voice Greeting: plays only on real Doorbell press (unless AUTO_REPLY_ONLY_BELL=0) and suppresses during Night DND
if [ -f /dev/alarm0.jpeg ] && [ ! -f /tmp/eye_auto_replied ]; then
    if [ -n "$AUTO_REPLY_SND" ] && [ "$AUTO_REPLY_SND" != "off" ]; then
        touch /tmp/eye_auto_replied
        (
            sleep 2
            load_eye_conf
            if ! is_dnd_now; then
                _ev=$(detect_event_type)
                if [ "${AUTO_REPLY_ONLY_BELL:-1}" != "1" ] || [ "$_ev" = "bell" ]; then
                    play_fastreply "$AUTO_REPLY_SND"
                fi
            fi
        ) >/dev/null 2>&1 &
    fi
fi

# Start local Russian Web Portal + Live MJPEG streamer on BusyBox httpd
_wport="${WEB_PORT:-8080}"
if ! ps | grep -v grep | grep -q "httpd -p $_wport"; then
    /usr/sbin/httpd -p "$_wport" -h /app/eye/www >/dev/null 2>&1 &
fi

# Wait for 802.11 association before trusting cached IP from /app/bin/recovery 1
_lwait=0
while [ $_lwait -lt 4 ]; do
    is_wifi_link_up && break
    usleep 500000 2>/dev/null || sleep 1
    _lwait=$((_lwait + 1))
done

# Wait for wlan0 IPv4 address only if associated to AP
_ip=""
if is_wifi_link_up; then
    _ip=$(get_wlan_ip)
    if [ -f /tmp/eye_force_dhcp ] || [ -z "$_ip" ]; then
        sleep 1
        _ip=$(get_wlan_ip)
        if [ -f /tmp/eye_force_dhcp ] || [ -z "$_ip" ]; then
            if ! ps | grep -v grep | grep -q 'udhcpc.*wlan0'; then
                udhcpc -b -i wlan0 -p /var/run/udhcpc.pid -R >/dev/null 2>&1 &
            fi
        fi
    fi

    _wait=0
    while [ $_wait -lt 16 ]; do
        _ip=$(get_wlan_ip)
        [ -n "$_ip" ] && break
        usleep 500000 2>/dev/null || sleep 1
        _wait=$((_wait + 1))
    done
fi

if is_wifi_connected; then
    # Update /tmp/os-release so Settings -> About on the peephole screen shows the live IP!
    write_os_release

    if [ -f /tmp/eye_force_dhcp ]; then
        rm -f /tmp/eye_force_dhcp
        /app/bin/recovery 0 >/dev/null 2>&1 || true
    fi

    # Program Cypress CYW43438 multi-slot WoWLAN filters & heartbeats (autonomous mode arms them in eye_pre_sleep.sh)
    if [ "${MI_CLOUD_ENABLE:-0}" = "1" ]; then
        apply_wowlan
    fi

    # Start UDP WoWLAN listener
    if ! ps | grep -v grep | grep -q 'eye_tool udplisten'; then
        /app/bin/eye_tool udplisten "${WOWLAN_PORT:-9999}" "${WOWLAN_KEY:-WAKEUP}" "/app/eye/tg_notify.sh --live" >/dev/null 2>&1 &
    fi

    # Sync time via NTP, push local TZ into /dev/rtc0 + LiteOS video OSD watermark, and re-apply Night DND RAM chime state
    if [ -n "$NTP_SERVER" ]; then
        (
            /usr/sbin/ntpd -n -q -p "$NTP_SERVER" >/dev/null 2>&1 &
            _npid=$!
            _nw=0
            while kill -0 "$_npid" 2>/dev/null && [ "$_nw" -lt 8 ]; do
                usleep 500000 2>/dev/null || sleep 1
                _nw=$((_nw + 1))
            done
            if kill -0 "$_npid" 2>/dev/null; then
                kill -9 "$_npid" 2>/dev/null || true
            fi
            wait "$_npid" 2>/dev/null || true
            echo "ntpd up=$(cut -d. -f1 /proc/uptime) $(date -u)" >> /tmp/eye_time.log
            sync_rtc_and_osd
            # Wait briefly so main_app finishes registering its cm_time_sync handler (~8s) without delaying sleep unnecessarily
            _sw=0
            while [ $_sw -lt 8 ]; do
                [ -f /tmp/force_sleep_now ] && exit 0
                sleep 1
                _sw=$((_sw + 1))
            done
            sync_rtc_and_osd
            apply_dnd_ram
        ) &
    else
        sync_rtc_and_osd
    fi

    # Instant wakeup notifications (MQTT + Home Assistant Webhook + Telegram + ntfy)
    if [ -f /dev/alarm0.jpeg ] && [ ! -f /tmp/eye_boot_alarm_sent ]; then
        get_uptime_s > /tmp/eye_boot_alarm_sent
        _ev=$(detect_event_type)
        _alarm_img="/tmp/tg_alarm.jpg"
        if [ "${CAM_ROTATE:-90}" != "0" ]; then
            /app/bin/eye_tool jpgrot /dev/alarm0.jpeg "$_alarm_img" "${CAM_ROTATE:-90}" 85 >/dev/null 2>&1 || _alarm_img="/dev/alarm0.jpeg"
        else
            cp -f /dev/alarm0.jpeg "$_alarm_img" 2>/dev/null || _alarm_img="/dev/alarm0.jpeg"
        fi
        cache_last_snap "$_alarm_img"
        send_mqtt_event "$_ev" "" "$_alarm_img"
        send_ha_webhook "$_ev" ""
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            /app/eye/tg_notify.sh --alarm "$_alarm_img" >/dev/null 2>&1 &
        elif [ -n "$NTFY_URL" ]; then
            send_ntfy_push "$_alarm_img" "$_ev"
        fi
    fi

    # Low battery warning check (waits briefly in background for main_app MCU ADC readiness; at most once every 12 hours)
    (
        _bw=0
        while [ $_bw -lt 12 ]; do
            [ -f /tmp/force_sleep_now ] && exit 0
            is_battery_live && break
            sleep 1
            _bw=$((_bw + 1))
        done
        if is_battery_live; then
            save_bat_cache >/dev/null 2>&1 || true
            _thr="${LOW_BAT_ALERT:-20}"
            _bat=$(get_live_battery_pct)
            case "$_bat" in
                ''|*[!0-9]*) ;;
                *)
                    case "$_thr" in
                        0|''|*[!0-9]*) ;;
                        *)
                            if [ "$_bat" -gt 0 ] && [ "$_bat" -le "$_thr" ]; then
                                _now_s=$(date +%s 2>/dev/null || echo 0)
                                _last_s=$(cat /app/sd/.low_bat_ts 2>/dev/null || echo 0)
                                case "$_last_s" in ''|*[!0-9]*) _last_s=0 ;; esac
                                if [ $((_now_s - _last_s)) -ge 43200 ] || [ "$_now_s" -lt "$_last_s" ]; then
                                    if grep -q ' /app/sd ' /proc/mounts 2>/dev/null; then
                                        echo "$_now_s" > /app/sd/.low_bat_ts 2>/dev/null || true
                                    fi
                                    /app/eye/tg_notify.sh --lowbat "$_bat" >/dev/null 2>&1 &
                                fi
                            fi
                            ;;
                    esac
                    ;;
            esac
        fi
    ) >/dev/null 2>&1 &
else
    if [ ! -f /tmp/eye_user_active ] && [ "$(/app/bin/factory get test 2>/dev/null)" != "1" ]; then
        trim_awake_if_idle 2
    fi
fi

rm -f /var/run/eye_post_wifi.lock
