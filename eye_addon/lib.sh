#!/bin/sh
# Common helper functions for Xiaobai M1 autonomous firmware (/app/eye/lib.sh)

PATH="/usr/bin:/usr/sbin:/bin:/sbin:/app:/app/bin"
LD_LIBRARY_PATH="/lib:/usr/lib:/usr/local/lib:/app/lib"
export PATH LD_LIBRARY_PATH

ensure_sd_mounted() {
    grep -q ' /app/sd ' /proc/mounts 2>/dev/null && return 0
    if [ ! -d /app/sd/MIJIA_RECORD_VIDEO ] && [ ! -f /app/sd/eye.conf ]; then
        if [ -b /dev/mmcblk0p1 ]; then
            mount -t vfat /dev/mmcblk0p1 /app/sd 2>/dev/null || true
        elif [ -b /dev/mmcblk0 ]; then
            mount -t vfat /dev/mmcblk0 /app/sd 2>/dev/null || true
        fi
    fi
}

find_eye_conf() {
    if [ -f /app/sd/eye.conf ]; then
        echo "/app/sd/eye.conf"
    elif [ -f /mnt/sdcard/eye.conf ]; then
        echo "/mnt/sdcard/eye.conf"
    else
        echo ""
    fi
}

load_eye_conf() {
    [ -f /app/eye/eye.conf.default ] && . /app/eye/eye.conf.default
    _conf=$(find_eye_conf)
    if [ -z "$_conf" ] && [ ! -f /tmp/eye.conf.clean ]; then
        if [ "$(/app/bin/factory get test 2>/dev/null)" = "1" ]; then
            ensure_sd_mounted
            _conf=$(find_eye_conf)
        fi
    fi
    if [ -n "$_conf" ] && [ -f "$_conf" ]; then
        tr -d '\r' < "$_conf" > /tmp/eye.conf.clean 2>/dev/null
        . /tmp/eye.conf.clean
    elif [ -f /tmp/eye.conf.clean ]; then
        . /tmp/eye.conf.clean
    fi
    if [ -z "${CAM_ROTATE:-}" ]; then
        if [ "${UI_ORIENT:-portrait}" = "landscape" ]; then CAM_ROTATE=0; else CAM_ROTATE=90; fi
    fi
    [ -z "${VO_ROTATE:-}" ] && VO_ROTATE=90
}

set_conf_kv() {
    _k="$1"
    _v="$2"
    [ -n "$_k" ] || return 1
    ensure_sd_mounted
    _target="/app/sd/eye.conf"
    if [ ! -f "$_target" ]; then
        if [ -f /app/sd/eye.conf.example ]; then
            cp /app/sd/eye.conf.example "$_target" 2>/dev/null || true
        elif [ -f /app/eye/eye.conf.example ]; then
            cp /app/eye/eye.conf.example "$_target" 2>/dev/null || true
        elif [ -f /app/eye/eye.conf.default ]; then
            cp /app/eye/eye.conf.default "$_target" 2>/dev/null || true
        fi
    fi
    case "$_v" in
        *[!0-9A-Za-z_.-]*|'')
            _esc=$(printf "%s" "$_v" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g')
            _line="${_k}=\"${_esc}\""
            ;;
        *)
            _line="${_k}=${_v}"
            ;;
    esac
    if [ -f "$_target" ]; then
        _lk=0
        while ! mkdir /tmp/eye_conf.lock 2>/dev/null && [ "$_lk" -lt 25 ]; do
            usleep 100000 2>/dev/null || sleep 1
            _lk=$((_lk + 1))
        done
        _kv_in="/tmp/eye.conf.kv.$$"
        _kv_out="/app/sd/.eye.conf.tmp.$$"
        tr -d '\r' < "$_target" > "$_kv_in" 2>/dev/null
        _replaced=0
        : > "$_kv_out"
        while IFS= read -r _rline || [ -n "$_rline" ]; do
            case "$_rline" in
                "${_k}="*)
                    if [ "$_replaced" -eq 0 ]; then
                        printf "%s\n" "$_line" >> "$_kv_out"
                        _replaced=1
                    fi
                    ;;
                *)
                    printf "%s\n" "$_rline" >> "$_kv_out"
                    ;;
            esac
        done < "$_kv_in"
        if [ "$_replaced" -eq 0 ]; then
            printf "%s\n" "$_line" >> "$_kv_out"
        fi
        if [ -s "$_kv_out" ]; then
            mv -f "$_kv_out" "$_target" 2>/dev/null || cp -f "$_kv_out" "$_target" 2>/dev/null || true
        fi
        rm -f "$_kv_in" "$_kv_out"
        sync
        rmdir /tmp/eye_conf.lock 2>/dev/null || true
    fi
    load_eye_conf
    return 0
}

get_nv() {
    _val=$(mortoxc get nvram default "$1" 2>/dev/null | tr -d '\r\n')
    if [ -z "$_val" ]; then
        echo "$2"
    else
        echo "$_val"
    fi
}

set_nv() {
    _key="$1"
    _val="$2"
    [ -n "$_key" ] || return 1
    mortoxc set nvram default "$_key" "$_val" >/dev/null 2>&1 || true
    mortoxc set mem default "$_key" "$_val" >/dev/null 2>&1 || true
    (/app/bin/backnv.sh >/dev/null 2>&1) &
    return 0
}

apply_tz() {
    echo "${TZ:-MSK-3}" > /tmp/TZ
}

# Push the correct local time into /dev/rtc0 and LiteOS video OSD watermark.
# main_app is patched to keep Linux in true UTC (no +/-28800 warp), while /dev/rtc0 stores local wall-clock time matching LiteOS /dev/hi_rtc.
sync_rtc_and_osd() {
    apply_tz
    _yr=$(date +%Y 2>/dev/null || echo 1970)
    case "$_yr" in ''|*[!0-9]*) _yr=1970 ;; esac
    [ "$_yr" -ge 2024 ] || return 0
    touch /tmp/eye_rtc_synced
    TZ="${TZ:-MSK-3}" hwclock -w -l >/dev/null 2>&1 || true
    (
        echo "osd sync start up=$(cut -d. -f1 /proc/uptime) $(date)" >> /tmp/eye_time.log
        # the handler fires on a value change -> toggle ok -> sync -> ok
        mortoxc set mem default cm_time_sync ok >/dev/null 2>&1 || true
        sleep 1
        mortoxc set mem default cm_time_sync sync >/dev/null 2>&1 || true
        sleep 1
        mortoxc set mem default cm_time_sync ok >/dev/null 2>&1 || true
        TZ="${TZ:-MSK-3}" hwclock -w -l >/dev/null 2>&1 || true
    ) >/dev/null 2>&1 &
}

# Overlay ROM sounds + optional custom user voices from /app/sd/voices/* into /tmp/sound (/app/sound)
# Copies custom voices into tmpfs RAM so /tmp/sound never pins /app/sd open across early unmount.
sync_custom_voices() {
    mkdir -p /tmp/sound
    if [ -d /app/sound_rom ]; then
        for _rf in /app/sound_rom/*; do
            [ -e "$_rf" ] || continue
            _rbn=$(basename "$_rf")
            [ -e "/tmp/sound/$_rbn" ] || ln -sf "$_rf" "/tmp/sound/$_rbn" 2>/dev/null || true
        done
    fi
    if [ -d /app/sd/voices ]; then
        for _vf in /app/sd/voices/*; do
            [ -f "$_vf" ] && [ -s "$_vf" ] || continue
            _vbn=$(basename "$_vf")
            rm -f "/tmp/sound/$_vbn" 2>/dev/null || true
            cp -f "$_vf" "/tmp/sound/$_vbn" 2>/dev/null || true
        done
    fi
}

has_custom_voice() {
    if [ -s /tmp/sound/05_custom ] || [ -s /app/sd/voices/05_custom ]; then
        return 0
    fi
    return 1
}

# Check whether Night Quiet Hours ("Тихий час", e.g. 23:00..08:00) are currently active
is_dnd_now() {
    [ "${DND_ENABLE:-0}" = "1" ] || return 1
    _yr=$(date +%Y 2>/dev/null || echo 1970)
    case "$_yr" in ''|*[!0-9]*) _yr=1970 ;; esac
    [ "$_yr" -ge 2024 ] || return 1

    _hr=$(date +%H 2>/dev/null | sed 's/^0//')
    [ -z "$_hr" ] && _hr=0
    _ds="${DND_START:-23}"
    _de="${DND_END:-8}"
    case "$_ds" in ''|*[!0-9]*) _ds=23 ;; esac
    case "$_de" in ''|*[!0-9]*) _de=8 ;; esac

    if [ "$_ds" -eq "$_de" ]; then
        return 0
    elif [ "$_ds" -lt "$_de" ]; then
        [ "$_hr" -ge "$_ds" ] && [ "$_hr" -lt "$_de" ] && return 0
    else
        if [ "$_hr" -ge "$_ds" ] || [ "$_hr" -lt "$_de" ]; then
            return 0
        fi
    fi
    return 1
}

# Mute indoor chime in RAM only (no Flash NVRAM wear!) during Quiet Hours
apply_dnd_ram() {
    if is_dnd_now && [ "${DND_MUTE_INDOOR:-1}" = "1" ]; then
        mortoxc set mem default doorbell_voice 0 >/dev/null 2>&1 || true
    else
        _saved_dbv=$(get_nv "doorbell_voice" "2")
        mortoxc set mem default doorbell_voice "$_saved_dbv" >/dev/null 2>&1 || true
    fi
}

# Show live Wi-Fi IP right inside Peephole Settings -> About ("ПО / IP") when MI_CLOUD_ENABLE=0
write_os_release() {
    _ver="4.3.5_3319"
    if [ "${MI_CLOUD_ENABLE:-0}" != "1" ]; then
        _cur_ip=$(get_wlan_ip)
        if [ -n "$_cur_ip" ]; then
            _ver="4.3.5 (${_cur_ip})"
        else
            _ver="4.3.5 RU Auto"
        fi
    fi
    cat > /tmp/os-release << EOF
NAME=Buildroot
VERSION=2017.08-00071-gfc473e4-dirty
ID=buildroot
VERSION_ID=2017.08
PRETTY_NAME="Buildroot 2017.08"
MODEL_COMMIT=ff7d1f4
COMMON_COMMIT=3b160e1
CHUANGMI_VERSION=${_ver}
CHUANGMI_BUILDNO=0
EOF
}

apply_vo_rotate() {
    rm -f /tmp/vo270 /tmp/vo0 /tmp/vo180 /tmp/vo90
    case "${VO_ROTATE:-90}" in
        270) touch /tmp/vo270 ;;
        0)   touch /tmp/vo0 ;;
        180) touch /tmp/vo180 ;;
        *)   ;;
    esac
}

set_cam_and_vo_rotate() {
    _cam_deg="${1:-0}"
    case "$_cam_deg" in
        0|90|180|270) ;;
        *) _cam_deg=0 ;;
    esac
    _ui_deg=90
    [ "${UI_ORIENT:-portrait}" = "landscape" ] && _ui_deg=0
    _vo_deg=$(( (90 + _cam_deg - _ui_deg + 360) % 360 ))
    set_conf_kv "CAM_ROTATE" "$_cam_deg"
    set_conf_kv "VO_ROTATE" "$_vo_deg"
    CAM_ROTATE="$_cam_deg"
    VO_ROTATE="$_vo_deg"
    apply_vo_rotate
}

get_uptime_s() {
    cut -d. -f1 /proc/uptime 2>/dev/null || echo 0
}

is_wifi_link_up() {
    if [ -e /proc/cywdhd ]; then
        echo "connection" > /proc/cywdhd 2>/dev/null || true
        _c=$(sed -n '1p' /proc/cywdhd 2>/dev/null | tr -cd '0-9')
        [ "$_c" = "1" ] || return 1
    fi
    return 0
}

is_wifi_connected() {
    [ -n "$(get_wlan_ip)" ] || return 1
    is_wifi_link_up || return 1
    return 0
}

extend_awake() {
    _sec="${1:-${KEEP_AWAKE_SEC:-35}}"
    case "$_sec" in
        ''|*[!0-9]*) _sec=35 ;;
    esac
    [ "$_sec" -gt 300 ] && _sec=300
    rm -f /tmp/force_sleep_now
    _now=$(get_uptime_s)
    _until=$((_now + _sec))
    if [ -f /tmp/eye_wake_until ]; then
        _cur=$(cat /tmp/eye_wake_until 2>/dev/null || echo 0)
        case "$_cur" in
            ''|*[!0-9]*) _cur=0 ;;
        esac
        if [ "$_cur" -gt "$_until" ] && [ $((_cur - _now)) -le 300 ]; then
            _until="$_cur"
        fi
    fi
    echo "$_until" > /tmp/eye_wake_until
    mortoxc set mem default max_client 1 >/dev/null 2>&1 || true
}

# Shorten remaining wake hold after silent pass-by PIR clip upload when user is not interacting
trim_awake_if_idle() {
    [ -f /tmp/eye_user_active ] && return 0
    _rem_s="${1:-5}"
    _now=$(get_uptime_s)
    echo $((_now + _rem_s)) > /tmp/eye_wake_until
}

# Clear crash-loop marker before intentional sleep or reboot
mark_clean_reboot() {
    if grep -q ' /app/sd ' /proc/mounts 2>/dev/null; then
        rm -f /app/sd/.eye_unclean_boot 2>/dev/null || true
        echo 0 > /app/sd/.eye_crash_cnt 2>/dev/null || true
    fi
}

# Instant 1-second hardware power-off via main_app sleep_hook (/tmp/force_sleep_now)
release_awake_now() {
    rm -f /tmp/eye_wake_until /tmp/eye_user_active
    touch /tmp/force_sleep_now
    /app/bin/recovery 0 >/dev/null 2>&1 || true
    mortoxc set mem default max_client 0 >/dev/null 2>&1 || true
}

ascii_to_hex() {
    printf "%s" "$1" | hexdump -ve '1/1 "%02x"' 2>/dev/null
}

# Multi-slot Cypress CYW43438 WoWLAN filters (101..109) + Multi-server Heartbeats (slots 2..9)
# Optional $1="pre_sleep" clears all preloaded driver/DHCP filters (100..109, including 100/104/105) right before sleep.
apply_wowlan() {
    [ -e /proc/cywdhd ] || return 0
    if [ "$1" != "pre_sleep" ] && [ "${MI_CLOUD_ENABLE:-0}" != "1" ]; then
        return 0
    fi
    _port="${WOWLAN_PORT:-9999}"
    _key="${WOWLAN_KEY:-WAKEUP}"
    _hex=$(ascii_to_hex "$_key")
    [ -z "$_hex" ] && _hex="57414b455550"

    if [ "$1" = "pre_sleep" ]; then
        echo "setfilter -c" > /proc/cywdhd 2>/dev/null || true
    fi

    # Primary broadcast & unicast magic packet filters (slots 101 & 102; stock slots 100/104/105 cleared in pre_sleep)
    echo "setfilter -b -i 101 -p $_port -P $_hex" > /proc/cywdhd 2>/dev/null || true
    echo "setfilter -u -i 102 -p $_port -P $_hex" > /proc/cywdhd 2>/dev/null || true

    # Optional extra UDP wake ports (slots 103..108)
    if [ -n "$EXTRA_WAKE_PORTS" ]; then
        _fidx=103
        for _ep in $EXTRA_WAKE_PORTS; do
            [ "$_fidx" -gt 108 ] && break
            case "$_ep" in
                ''|*[!0-9]*) ;;
                *)
                    echo "setfilter -u -b -i $_fidx -p $_ep -P $_hex" > /proc/cywdhd 2>/dev/null || true
                    _fidx=$((_fidx + 1))
                    ;;
            esac
        done
    fi

    # Optional wake-on-ICMP-ping in slot 109
    if [ "${PING_WAKE:-0}" = "1" ]; then
        echo "setfilter -m -i 109" > /proc/cywdhd 2>/dev/null || true
    else
        echo "setfilter -c109" > /proc/cywdhd 2>/dev/null || true
    fi

    # Multi-server NAT keepalive heartbeats in hardware slots -d 2..9 using string payload -p
    # Supports "auto:<port>" (resolves current router gateway IP dynamically via get_gateway_ip)
    if [ -n "$HEARTBEAT_SERVERS" ]; then
        _slot=2
        for _srv in $HEARTBEAT_SERVERS; do
            [ "$_slot" -gt 9 ] && break
            _sip="${_srv%:*}"
            _sport="${_srv#*:}"
            if [ "$_sip" = "auto" ] || [ "$_sip" = "gateway" ]; then
                _sip=$(get_gateway_ip)
            fi
            if [ -n "$_sip" ] && [ -n "$_sport" ] && [ "$_sip" != "$_sport" ]; then
                echo "hb -u -d $_slot -p $_key -i 50 $_sip $_sport" > /proc/cywdhd 2>/dev/null || true
                _slot=$((_slot + 1))
            fi
        done
    fi
}

# Detect exact hardware wakeup / recording reason: "bell" | "stay" | "motion"
detect_event_type() {
    if [ -f /tmp/eye_event_type ]; then
        _ev=$(cat /tmp/eye_event_type 2>/dev/null)
        [ -n "$_ev" ] && [ "$_ev" != "unknown" ] && { echo "$_ev"; return 0; }
    fi
    if grep -qE 'set bell status = 1|event\.bell|BellVideo|add video 2 ' /tmp/main_app.log /tmp/liteos_log 2>/dev/null; then
        echo "bell" > /tmp/eye_event_type
        echo "bell"
        return 0
    fi
    if grep -qE 'Stay|stick_around|add video 1 ' /tmp/main_app.log /tmp/liteos_log 2>/dev/null; then
        echo "stay" > /tmp/eye_event_type
        echo "stay"
        return 0
    fi
    if grep -qE 'PIR Boot:1|event\.motion|Pass|add video 0 ' /tmp/main_app.log /tmp/liteos_log 2>/dev/null; then
        echo "motion"
        return 0
    fi
    echo "alarm"
}

event_title_ru() {
    case "$1" in
        bell)        echo "🔔 ЗВОНОК В ДВЕРЬ!" ;;
        stay)        echo "🧍 КТО-ТО СТОИТ У ДВЕРИ" ;;
        motion)      echo "🚶 ДВИЖЕНИЕ У ДВЕРИ" ;;
        lowbat)      echo "🪫 НИЗКИЙ ЗАРЯД БАТАРЕИ" ;;
        manual)      echo "🎬 РУЧНАЯ ЗАПИСЬ С ГЛАЗКА" ;;
        manual_snap) echo "📸 СНИМОК С ЭКРАНА ГЛАЗКА" ;;
        *)           echo "🔔 СОБЫТИЕ У ДВЕРИ" ;;
    esac
}

# Optional lockscreen push via ntfy.sh / self-hosted ntfy
send_ntfy_push() {
    [ -n "$NTFY_URL" ] || return 0
    _img="$1"
    _ev="$2"
    _bat=$(get_battery_pct)
    _prio="default"
    [ "$_ev" = "bell" ] && _prio="high"
    is_dnd_now && [ "$_ev" != "bell" ] && _prio="low"
    if [ -n "$_img" ] && [ -f "$_img" ]; then
        /app/bin/curl -s -k --connect-timeout 6 --max-time 15 \
            -H "Title: Xiaobai M1 (${_ev}) - ${_bat}%" \
            -H "Priority: ${_prio}" \
            -H "Filename: door.jpg" \
            -T "$_img" "$NTFY_URL" >/dev/null 2>&1 &
    else
        /app/bin/curl -s -k --connect-timeout 6 --max-time 10 \
            -H "Title: Xiaobai M1 (${_bat}%)" \
            -H "Priority: ${_prio}" \
            -d "$(event_title_ru "$_ev")" "$NTFY_URL" >/dev/null 2>&1 &
    fi
}

# Optional Home Assistant / Node-RED / Sprut.hub JSON webhook
send_ha_webhook() {
    [ -n "$WEBHOOK_URL" ] || return 0
    _ev=$(printf "%s" "${1:-alarm}" | tr -d '"\\')
    _rel=$(printf "%s" "${2:-}" | tr -d '"\\')
    _bat=$(get_battery_pct)
    case "$_bat" in ''|*[!0-9]*) _bat=0 ;; esac
    _bv=$(get_battery_v)
    _bv_json=""
    [ -n "$_bv" ] && _bv_json=",\"battery_v\":${_bv}"
    _rssi=$(get_wifi_rssi)
    case "$_rssi" in ''|*[!0-9-]*) _rssi=-60 ;; esac
    _ip=$(get_wlan_ip)
    _wport="${WEB_PORT:-8080}"
    _payload="{\"event\":\"${_ev}\",\"battery\":${_bat}${_bv_json},\"rssi\":${_rssi},\"ip\":\"${_ip}\",\"live_jpg\":\"http://${_ip}:${_wport}/live.jpg\",\"clip\":\"${_rel}\"}"
    /app/bin/curl -s -k --connect-timeout 5 --max-time 10 \
        -X POST -H "Content-Type: application/json" \
        -d "$_payload" "$WEBHOOK_URL" >/dev/null 2>&1 &
}

# Native Local MQTT v3.1.1 + Home Assistant MQTT Auto-Discovery v4 (< 15 ms LAN, 0 mA when disabled or in sleep)
mqtt_is_tripped() {
    [ -f /tmp/mqtt_unreachable ] || return 1
    _mts=$(cat /tmp/mqtt_unreachable 2>/dev/null || echo 0)
    case "$_mts" in ''|*[!0-9]*) _mts=0 ;; esac
    _mnow=$(get_uptime_s)
    if [ $((_mnow - _mts)) -lt 60 ] && [ "$_mnow" -ge "$_mts" ]; then
        return 0
    fi
    rm -f /tmp/mqtt_unreachable
    return 1
}

mqtt_mark_unreachable() {
    get_uptime_s > /tmp/mqtt_unreachable 2>/dev/null || true
}

mqtt_run_pub() {
    /app/bin/eye_tool mqttpub "$MQTT_HOST" "${MQTT_PORT:-1883}" "$1" "$2" "${MQTT_USER:-}" "${MQTT_PASS:-}" "${3:-0}" >/dev/null 2>&1
    _mrc=$?
    if [ "$_mrc" -ne 0 ]; then
        mqtt_mark_unreachable
        return "$_mrc"
    fi
    return 0
}

mqtt_run_pub_file() {
    /app/bin/eye_tool mqttpub_file "$MQTT_HOST" "${MQTT_PORT:-1883}" "$1" "$2" "${MQTT_USER:-}" "${MQTT_PASS:-}" "${3:-0}" >/dev/null 2>&1
    _mrc=$?
    if [ "$_mrc" -ne 0 ]; then
        mqtt_mark_unreachable
        return "$_mrc"
    fi
    return 0
}

mqtt_ensure_discovery() {
    _pfx="${MQTT_PREFIX:-xiaobai_m1}"
    _disc_id=$(printf "%s_%s" "$MQTT_HOST" "$_pfx" | tr -cd 'A-Za-z0-9_.-')
    _disc_stamp="/app/sd/.mqtt_disc_v4_${_disc_id}"
    { [ -f "$_disc_stamp" ] || [ -f /tmp/mqtt_disc_sent ]; } && return 0

    _ip=$(get_wlan_ip)
    _wport="${WEB_PORT:-8080}"
    _cu_json=""
    [ -n "$_ip" ] && _cu_json=",\"cu\":\"http://${_ip}:${_wport}/\""
    _dev="\"dev\":{\"ids\":[\"${_pfx}\"],\"name\":\"Умный глазок Xiaobai M1\",\"mdl\":\"CMMY18A\",\"mf\":\"Xiaomi / Xiaobai\",\"sw\":\"4.3.5 RU\"${_cu_json}}"

    # Clear legacy v3 retained status topic so HA restarts never replay old "bell":"ON"
    mqtt_run_pub "${_pfx}/status" "" 1 || return $?
    mqtt_run_pub "${_pfx}/event" "{\"event\":\"idle\",\"bell\":\"OFF\",\"motion\":\"OFF\",\"stay\":\"OFF\"}" 1 || return $?
    mqtt_run_pub "homeassistant/camera/${_pfx}_cam/config" \
        "{\"name\":\"Камера у двери\",\"uniq_id\":\"${_pfx}_cam\",\"topic\":\"${_pfx}/snapshot\",${_dev}}" 1 && \
    mqtt_run_pub "homeassistant/binary_sensor/${_pfx}_bell/config" \
        "{\"name\":\"Звонок в дверь\",\"uniq_id\":\"${_pfx}_bell\",\"stat_t\":\"${_pfx}/event\",\"val_tpl\":\"{{ value_json.bell }}\",\"pl_on\":\"ON\",\"pl_off\":\"OFF\",\"off_dly\":15,${_dev}}" 1 && \
    mqtt_run_pub "homeassistant/binary_sensor/${_pfx}_motion/config" \
        "{\"name\":\"Движение у двери\",\"uniq_id\":\"${_pfx}_motion\",\"stat_t\":\"${_pfx}/event\",\"val_tpl\":\"{{ value_json.motion }}\",\"dev_cla\":\"motion\",\"pl_on\":\"ON\",\"pl_off\":\"OFF\",\"off_dly\":20,${_dev}}" 1 && \
    mqtt_run_pub "homeassistant/binary_sensor/${_pfx}_stay/config" \
        "{\"name\":\"Кто-то стоит у двери\",\"uniq_id\":\"${_pfx}_stay\",\"stat_t\":\"${_pfx}/event\",\"val_tpl\":\"{{ value_json.stay }}\",\"dev_cla\":\"occupancy\",\"pl_on\":\"ON\",\"pl_off\":\"OFF\",\"off_dly\":25,${_dev}}" 1 && \
    mqtt_run_pub "homeassistant/sensor/${_pfx}_event/config" \
        "{\"name\":\"Последнее событие\",\"uniq_id\":\"${_pfx}_event\",\"stat_t\":\"${_pfx}/telemetry\",\"val_tpl\":\"{{ value_json.event }}\",\"json_attr_t\":\"${_pfx}/telemetry\",\"icon\":\"mdi:doorbell-video\",${_dev}}" 1 && \
    mqtt_run_pub "homeassistant/sensor/${_pfx}_state/config" \
        "{\"name\":\"Состояние\",\"uniq_id\":\"${_pfx}_state\",\"stat_t\":\"${_pfx}/telemetry\",\"val_tpl\":\"{{ value_json.state }}\",\"icon\":\"mdi:power-sleep\",${_dev}}" 1 && \
    mqtt_run_pub "homeassistant/sensor/${_pfx}_battery/config" \
        "{\"name\":\"Заряд батареи\",\"uniq_id\":\"${_pfx}_bat\",\"stat_t\":\"${_pfx}/telemetry\",\"val_tpl\":\"{{ value_json.battery }}\",\"unit_of_meas\":\"%\",\"dev_cla\":\"battery\",\"stat_cla\":\"measurement\",${_dev}}" 1 && \
    mqtt_run_pub "homeassistant/sensor/${_pfx}_battery_v/config" \
        "{\"name\":\"Напряжение батареи\",\"uniq_id\":\"${_pfx}_bat_v\",\"stat_t\":\"${_pfx}/telemetry\",\"val_tpl\":\"{{ value_json.battery_v if value_json.battery_v is defined else none }}\",\"unit_of_meas\":\"V\",\"dev_cla\":\"voltage\",\"stat_cla\":\"measurement\",${_dev}}" 1 && \
    mqtt_run_pub "homeassistant/sensor/${_pfx}_rssi/config" \
        "{\"name\":\"Сигнал Wi-Fi\",\"uniq_id\":\"${_pfx}_rssi\",\"stat_t\":\"${_pfx}/telemetry\",\"val_tpl\":\"{{ value_json.rssi }}\",\"unit_of_meas\":\"dBm\",\"dev_cla\":\"signal_strength\",\"stat_cla\":\"measurement\",${_dev}}" 1 && \
    mqtt_run_pub "homeassistant/sensor/${_pfx}_sd/config" \
        "{\"name\":\"MicroSD\",\"uniq_id\":\"${_pfx}_sd\",\"stat_t\":\"${_pfx}/telemetry\",\"val_tpl\":\"{{ value_json.sd }}\",\"icon\":\"mdi:microsd\",${_dev}}" 1 && \
    { touch /tmp/mqtt_disc_sent; touch "$_disc_stamp" 2>/dev/null || true; }
}

mqtt_build_telemetry_json() {
    _mev=$(printf "%s" "${1:-idle}" | tr -d '"\\')
    _mrel=$(printf "%s" "${2:-}" | tr -d '"\\')
    _mst=$(printf "%s" "${3:-awake}" | tr -d '"\\')
    _bat=$(get_battery_pct)
    case "$_bat" in ''|*[!0-9]*) _bat=0 ;; esac
    _bv=$(get_battery_v)
    _bv_json=""
    [ -n "$_bv" ] && _bv_json=",\"battery_v\":${_bv}"
    _rssi=$(get_wifi_rssi)
    case "$_rssi" in ''|*[!0-9-]*) _rssi=-60 ;; esac
    _ip=$(get_wlan_ip)
    _wport="${WEB_PORT:-8080}"
    _sd_str=$(get_sd_usage_str | tr -d '"\\')
    _now_str=$(date '+%d.%m.%Y %H:%M:%S' 2>/dev/null || echo "")
    _clip_url=""
    [ -n "$_mrel" ] && _clip_url="http://${_ip}:${_wport}/sd/${_mrel}"
    printf "{\"event\":\"%s\",\"state\":\"%s\",\"battery\":%s%s,\"rssi\":%s,\"ip\":\"%s\",\"sd\":\"%s\",\"time\":\"%s\",\"live_jpg\":\"http://%s:%s/live.jpg\",\"clip\":\"%s\",\"clip_url\":\"%s\"}" \
        "$_mev" "$_mst" "$_bat" "$_bv_json" "$_rssi" "$_ip" "$_sd_str" "$_now_str" "$_ip" "$_wport" "$_mrel" "$_clip_url"
}

send_mqtt_telemetry_sync() {
    [ "${MQTT_ENABLE:-0}" = "1" ] && [ -n "$MQTT_HOST" ] || return 0
    mqtt_is_tripped && return 0
    _st="${1:-awake}"
    _ev_last=$(cat /tmp/mqtt_last_ev 2>/dev/null || true)
    [ -z "$_ev_last" ] && _ev_last="idle"
    _rel_last=$(cat /tmp/mqtt_last_clip 2>/dev/null || true)
    mqtt_ensure_discovery || return 1
    _pfx="${MQTT_PREFIX:-xiaobai_m1}"
    _json=$(mqtt_build_telemetry_json "$_ev_last" "$_rel_last" "$_st")
    mqtt_run_pub "${_pfx}/telemetry" "$_json" 1 || return 1
    return 0
}

send_mqtt_event() {
    [ "${MQTT_ENABLE:-0}" = "1" ] && [ -n "$MQTT_HOST" ] || return 0
    mqtt_is_tripped && return 0
    _ev="$1"
    _rel="$2"
    _jpg="$3"
    [ -n "$_ev" ] && printf "%s" "$_ev" > /tmp/mqtt_last_ev 2>/dev/null || true
    [ -n "$_rel" ] && printf "%s" "$_rel" > /tmp/mqtt_last_clip 2>/dev/null || true
    (
        _pfx="${MQTT_PREFIX:-xiaobai_m1}"
        mqtt_ensure_discovery || exit 0
        _bell_on="OFF"
        _mot_on="OFF"
        _stay_on="OFF"
        if [ "$_ev" = "bell" ]; then
            _bell_on="ON"
            _mot_on="ON"
            _stay_on="ON"
        elif [ "$_ev" = "stay" ]; then
            _mot_on="ON"
            _stay_on="ON"
        elif [ "$_ev" = "motion" ] || [ "$_ev" = "alarm" ]; then
            _mot_on="ON"
        fi
        _ev_json="{\"event\":\"${_ev}\",\"bell\":\"${_bell_on}\",\"motion\":\"${_mot_on}\",\"stay\":\"${_stay_on}\"}"
        mqtt_run_pub "${_pfx}/event" "$_ev_json" 0 || exit 0
        _tel_json=$(mqtt_build_telemetry_json "$_ev" "$_rel" "awake")
        mqtt_run_pub "${_pfx}/telemetry" "$_tel_json" 1 || exit 0
        if [ -n "$_jpg" ] && [ -s "$_jpg" ]; then
            mqtt_run_pub_file "${_pfx}/snapshot" "$_jpg" 1 || true
        fi
    ) >/dev/null 2>&1 &
}

cache_last_snap() {
    _src="$1"
    [ -n "$_src" ] && [ -s "$_src" ] || return 1
    ensure_sd_mounted
    if grep -q ' /app/sd ' /proc/mounts 2>/dev/null; then
        cp -f "$_src" /app/sd/.last_snap.jpg 2>/dev/null || true
    fi
    return 0
}

get_mqtt_fallback_snap() {
    if [ -s /tmp/web_snap.jpg ]; then
        echo "/tmp/web_snap.jpg"
        return 0
    fi
    if [ -s /tmp/tg_alarm.jpg ]; then
        echo "/tmp/tg_alarm.jpg"
        return 0
    fi
    ensure_sd_mounted
    if [ -s /app/sd/.last_snap.jpg ]; then
        echo "/app/sd/.last_snap.jpg"
        return 0
    fi
    if [ -d /app/sd/MIJIA_RECORD_VIDEO ]; then
        _arch=$(find /app/sd/MIJIA_RECORD_VIDEO -type f -name "*.jpeg" 2>/dev/null | sort -r | head -n 1)
        if [ -n "$_arch" ] && [ -s "$_arch" ]; then
            echo "$_arch"
            return 0
        fi
    fi
    return 1
}

send_mqtt_snapshot() {
    _jpg="$1"
    _ev="${2:-live}"
    [ -n "$_jpg" ] && [ -s "$_jpg" ] || return 0
    cache_last_snap "$_jpg"
    [ "${MQTT_ENABLE:-0}" = "1" ] && [ -n "$MQTT_HOST" ] || return 0
    mqtt_is_tripped && return 0
    [ -n "$_ev" ] && printf "%s" "$_ev" > /tmp/mqtt_last_ev 2>/dev/null || true
    (
        _pfx="${MQTT_PREFIX:-xiaobai_m1}"
        mqtt_ensure_discovery || exit 0
        mqtt_run_pub_file "${_pfx}/snapshot" "$_jpg" 1 || exit 0
        _rel_last=$(cat /tmp/mqtt_last_clip 2>/dev/null || true)
        _tel_json=$(mqtt_build_telemetry_json "$_ev" "$_rel_last" "awake")
        mqtt_run_pub "${_pfx}/telemetry" "$_tel_json" 1 || true
    ) >/dev/null 2>&1 &
}

# Reliable FTP / FTPS / WebDAV PUT backup of fresh MP4 & JPEG to router USB / NAS
# Holds wake lock during transfer so SoC never powers off mid-upload even when Telegram is not configured!
upload_net_backup() {
    [ -n "$BACKUP_URL" ] || return 0
    _mp4="$1"
    _jpg="$2"
    _ev="${3:-clip}"
    (
        extend_awake 25
        _base="${BACKUP_URL%/}"
        _day=$(date '+%Y-%m-%d' 2>/dev/null || echo "clips")
        _ts=$(date '+%H-%M-%S' 2>/dev/null || basename "$_mp4" .mp4)
        _stem="${_ts}_${_ev}"
        case "$_base" in
            http://*|https://*)
                # WebDAV PUT: create date folder via MKCOL (falls back to flat dated filename if MKCOL unsupported)
                /app/bin/curl -s -k --connect-timeout 5 --max-time 8 -X MKCOL "${_base}/${_day}/" >/dev/null 2>&1 || true
                if [ -f "$_mp4" ]; then
                    /app/bin/curl -s -k --connect-timeout 8 --max-time 45 -T "$_mp4" "${_base}/${_day}/${_stem}.mp4" >/dev/null 2>&1 || \
                    /app/bin/curl -s -k --connect-timeout 8 --max-time 45 -T "$_mp4" "${_base}/${_day}_${_stem}.mp4" >/dev/null 2>&1 || true
                fi
                if [ -n "$_jpg" ] && [ -f "$_jpg" ]; then
                    /app/bin/curl -s -k --connect-timeout 8 --max-time 20 -T "$_jpg" "${_base}/${_day}/${_stem}.jpg" >/dev/null 2>&1 || \
                    /app/bin/curl -s -k --connect-timeout 8 --max-time 20 -T "$_jpg" "${_base}/${_day}_${_stem}.jpg" >/dev/null 2>&1 || true
                fi
                ;;
            *)
                # FTP / FTPS with automatic dated subdirectory creation
                if [ -f "$_mp4" ]; then
                    /app/bin/curl -s -k --connect-timeout 8 --max-time 45 --ftp-create-dirs \
                        -T "$_mp4" "${_base}/${_day}/${_stem}.mp4" >/dev/null 2>&1 || true
                fi
                if [ -n "$_jpg" ] && [ -f "$_jpg" ]; then
                    /app/bin/curl -s -k --connect-timeout 8 --max-time 20 --ftp-create-dirs \
                        -T "$_jpg" "${_base}/${_day}/${_stem}.jpg" >/dev/null 2>&1 || true
                fi
                ;;
        esac
        if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
            trim_awake_if_idle 3
        fi
    ) >/dev/null 2>&1 &
}

play_fastreply() {
    _snd="$1"
    _vol="${2:-${SPEAKER_VOL:-2}}"
    case "$_vol" in
        1|2) ;;
        *) _vol=2 ;;
    esac
    sync_custom_voices
    if [ -n "$_snd" ] && [ -f "/app/sound/$_snd" ]; then
        mortoxc set mem default ipc018_sound_play "${_snd}@#${_vol}" >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

format_clip_label() {
    _rel="$1"
    _fmt=$(printf "%s" "$_rel" | sed -n 's#^....\([0-9][0-9]\)\([0-9][0-9]\)\([0-9][0-9]\)/\([0-9][0-9]\)M\([0-9][0-9]\)S.*#\2.\1 \3:\4#p')
    if [ -n "$_fmt" ]; then
        printf "%s" "$_fmt"
    else
        basename "$_rel" .mp4
    fi
}

tz_label_ru() {
    case "$1" in
        EET-2)  echo "UTC+2 (Калининград)" ;;
        MSK-3)  echo "UTC+3 (Москва)" ;;
        SAMT-4) echo "UTC+4 (Самара)" ;;
        YEKT-5) echo "UTC+5 (Екатеринбург)" ;;
        OMST-6) echo "UTC+6 (Омск)" ;;
        KRAT-7) echo "UTC+7 (Красноярск)" ;;
        IRKT-8) echo "UTC+8 (Иркутск)" ;;
        VLAT-10) echo "UTC+10 (Владивосток)" ;;
        *)      echo "$1" ;;
    esac
}

tg_curl() {
    if [ -f /tmp/tg_unreachable ]; then
        _uts=$(cat /tmp/tg_unreachable 2>/dev/null || echo 0)
        _now=$(get_uptime_s)
        case "$_uts" in ''|*[!0-9]*) _uts=0 ;; esac
        if [ "$_now" -ge "$_uts" ] && [ $((_now - _uts)) -lt 60 ]; then
            return 1
        fi
        rm -f /tmp/tg_unreachable
    fi
    if [ -n "$TG_PROXY" ]; then
        /app/bin/curl -s -k --connect-timeout 4 --max-time 15 -x "$TG_PROXY" "$@"
    else
        /app/bin/curl -s -k --connect-timeout 4 --max-time 15 "$@"
    fi
    _rc=$?
    case "$_rc" in
        6|7|28) get_uptime_s > /tmp/tg_unreachable 2>/dev/null || true ;;
    esac
    return $_rc
}

get_wlan_ip() {
    ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -n 1
}

get_gateway_ip() {
    route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $2; exit}'
}

get_wifi_rssi() {
    _r=""
    if [ -e /proc/cywdhd ]; then
        echo "rssi" > /proc/cywdhd 2>/dev/null || true
        _r=$(sed -n '1p' /proc/cywdhd 2>/dev/null | tr -cd '0-9-')
    fi
    if [ -z "$_r" ] && [ -x /app/bin/wl ]; then
        _r=$(/app/bin/wl rssi 2>/dev/null | tr -cd '0-9-')
    fi
    if [ -z "$_r" ]; then
        _r=$(awk 'NR==3{gsub(/\./,"",$4); print $4}' /proc/net/wireless 2>/dev/null | tr -cd '0-9-')
    fi
    case "$_r" in
        -[0-9]*) echo "$_r" ;;
        [1-9]*)  echo "-$_r" ;;
        *)       echo "?" ;;
    esac
}

read_bat_cache() {
    _rk="$1"
    _cf=""
    if [ -f /tmp/eye_bat_cache ]; then
        _cf="/tmp/eye_bat_cache"
    elif grep -q ' /app/sd ' /proc/mounts 2>/dev/null && [ -f /app/sd/.eye_bat_cache ]; then
        _cf="/app/sd/.eye_bat_cache"
    fi
    [ -n "$_cf" ] || return 1
    sed -n "s/^${_rk}=//p" "$_cf" 2>/dev/null | head -n 1 | tr -d '\r\n'
}

get_live_battery_pct() {
    _b=$(mortoxc get mem default bat_value 2>/dev/null | tr -d '\r\n ')
    case "$_b" in
        ''|0|*[!0-9]*)
            # main_app logs "no charging,adc = N,percent = P,offset = O" to syslog (/tmp/messages), not main_app.log
            _b=$(tail -n 200 /tmp/messages 2>/dev/null | sed -n 's/.*adc = [0-9]*,percent = \([0-9][0-9]*\).*/\1/p' | tail -n 1)
            ;;
    esac
    case "$_b" in
        ''|*[!0-9]*) echo "" ;;
        *) echo "$_b" ;;
    esac
}

is_battery_live() {
    [ -n "$(get_live_battery_pct)" ]
}

get_sd_usage_str() {
    if grep -q ' /app/sd ' /proc/mounts 2>/dev/null; then
        _sd=$(df -h /app/sd 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')
        if [ -n "$_sd" ]; then
            printf "%s" "$_sd"
            return 0
        fi
    fi
    _csd=$(read_bat_cache "CACHED_SD" 2>/dev/null || true)
    if [ -n "$_csd" ]; then
        printf "%s" "$_csd"
    else
        printf "Монтируется..."
    fi
}

get_battery_pct() {
    _b=$(get_live_battery_pct)
    case "$_b" in
        ''|*[!0-9]*)
            _b=$(read_bat_cache "CACHED_BAT" 2>/dev/null || true)
            ;;
    esac
    case "$_b" in
        ''|*[!0-9]*) echo "?" ;;
        *) echo "$_b" ;;
    esac
}

# Read calibrated battery voltage in mV from MCU ADC telemetry (exact main_app formula: adc*585/1000 + vbatoffset)
get_battery_mv() {
    _off=""
    if [ -f /tmp/main_app.log ]; then
        _off=$(sed -n 's/.*offset = \([-0-9][0-9]*\).*/\1/p' /tmp/main_app.log 2>/dev/null | tail -n 1)
    fi
    if [ -z "$_off" ] && [ -f /tmp/eye_vbatoffset ]; then
        _off=$(cat /tmp/eye_vbatoffset 2>/dev/null | tr -d '\r\n ')
    fi
    case "${_off#-}" in
        ''|*[!0-9]*)
            _hwv=$(/app/bin/factory get hw_ver 2>/dev/null | tr -d '\r\n ')
            if [ "$_hwv" = "1" ]; then
                _off=-50
            else
                _fo=$(/app/bin/factory get vbatoffset 2>/dev/null | tr -d '\r\n ')
                case "${_fo#-}" in
                    ''|*[!0-9]*) _off=0 ;;
                    *)
                        if [ "$_fo" != "-" ] && [ "$_fo" -gt 100 ] 2>/dev/null; then
                            _off=-50
                        elif [ "$_fo" != "-" ]; then
                            _off="$_fo"
                        else
                            _off=0
                        fi
                        ;;
                esac
            fi
            ;;
    esac
    [ "$_off" = "-" ] && _off=0
    echo "$_off" > /tmp/eye_vbatoffset 2>/dev/null || true

    _adc=""
    if [ -f /tmp/messages ]; then
        _adc=$(tail -n 200 /tmp/messages 2>/dev/null | sed -n 's/.*adc = \([0-9][0-9]*\),percent.*/\1/p' | tail -n 1)
        _moff=$(tail -n 200 /tmp/messages 2>/dev/null | sed -n 's/.*percent = [0-9]*,offset = \([-0-9][0-9]*\).*/\1/p' | tail -n 1)
        [ -n "$_moff" ] && _off="$_moff"
    fi
    if [ -z "$_adc" ] && [ -f /tmp/main_app.log ]; then
        _adc=$(sed -n 's/.*mcu now_bat_adc_value = \([0-9][0-9]*\).*/\1/p' /tmp/main_app.log 2>/dev/null | tail -n 1)
        if [ -z "$_adc" ]; then
            _adc=$(sed -n 's/.*adc = \([0-9][0-9]*\),percent.*/\1/p' /tmp/main_app.log 2>/dev/null | tail -n 1)
        fi
    fi
    case "$_adc" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$_adc" -gt 1000 ] 2>/dev/null; then
                _mv=$(( (_adc * 585) / 1000 + _off ))
                if [ "$_mv" -ge 2500 ] && [ "$_mv" -le 4500 ]; then
                    echo "$_mv" > /tmp/eye_bat_mv 2>/dev/null || true
                    echo "$_mv"
                    return 0
                fi
            fi
            ;;
    esac
    if [ -f /tmp/eye_bat_mv ]; then
        cat /tmp/eye_bat_mv 2>/dev/null | tr -d '\r\n '
        return 0
    fi
    _cmv=$(read_bat_cache "CACHED_MV" 2>/dev/null || true)
    case "$_cmv" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$_cmv" -ge 2500 ] && [ "$_cmv" -le 4500 ]; then
                echo "$_cmv"
                return 0
            fi
            ;;
    esac
    echo ""
}

save_bat_cache() {
    _lb=$(get_live_battery_pct)
    case "$_lb" in ''|*[!0-9]*) return 1 ;; esac
    _lmv=$(get_battery_mv)
    _lsd=""
    if grep -q ' /app/sd ' /proc/mounts 2>/dev/null; then
        _lsd=$(df -h /app/sd 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')
    fi
    [ -z "$_lsd" ] && _lsd=$(read_bat_cache "CACHED_SD" 2>/dev/null || true)
    printf "CACHED_BAT=%s\nCACHED_MV=%s\nCACHED_SD=%s\n" "$_lb" "$_lmv" "$_lsd" > /tmp/eye_bat_cache.tmp 2>/dev/null && \
        mv -f /tmp/eye_bat_cache.tmp /tmp/eye_bat_cache 2>/dev/null || true
    if grep -q ' /app/sd ' /proc/mounts 2>/dev/null; then
        _need_sd=0
        if [ ! -f /app/sd/.eye_bat_cache ]; then
            _need_sd=1
        else
            _obat=$(sed -n 's/^CACHED_BAT=//p' /app/sd/.eye_bat_cache 2>/dev/null | head -n 1 | tr -d '\r\n')
            _omv=$(sed -n 's/^CACHED_MV=//p' /app/sd/.eye_bat_cache 2>/dev/null | head -n 1 | tr -d '\r\n')
            _osd=$(sed -n 's/^CACHED_SD=//p' /app/sd/.eye_bat_cache 2>/dev/null | head -n 1 | tr -d '\r\n')
            if [ "$_obat" != "$_lb" ] || { [ -n "$_lsd" ] && [ -z "$_osd" ]; }; then
                _need_sd=1
            elif [ -n "$_lmv" ]; then
                case "$_omv" in
                    ''|*[!0-9]*) _need_sd=1 ;;
                    *)
                        _dmv=$((_lmv - _omv))
                        [ "$_dmv" -lt 0 ] && _dmv=$((-_dmv))
                        [ "$_dmv" -ge 30 ] && _need_sd=1
                        ;;
                esac
            fi
        fi
        if [ "$_need_sd" -eq 1 ]; then
            cp -f /tmp/eye_bat_cache /app/sd/.eye_bat_cache.tmp 2>/dev/null && \
                mv -f /app/sd/.eye_bat_cache.tmp /app/sd/.eye_bat_cache 2>/dev/null || true
        fi
    fi
    return 0
}

get_battery_v() {
    _mv=$(get_battery_mv)
    case "$_mv" in
        ''|*[!0-9]*) echo "" ;;
        *)
            _cv=$(( (_mv + 5) / 10 ))
            printf "%d.%02d" $((_cv / 100)) $((_cv % 100))
            ;;
    esac
}

get_battery_label() {
    _bp=$(get_battery_pct)
    _bv=$(get_battery_v)
    if [ -n "$_bv" ]; then
        printf "%s%% (%s В)" "$_bp" "$_bv"
    else
        printf "%s%%" "$_bp"
    fi
}

is_low_battery_saver() {
    _bp=$(get_battery_pct)
    _thr="${LOW_BAT_ALERT:-20}"
    case "$_thr" in ''|0|*[!0-9]*) _thr=20 ;; esac
    case "$_bp" in
        ''|*[!0-9]*) return 1 ;;
        *)
            [ "$_bp" -gt 0 ] && [ "$_bp" -le "$_thr" ] && return 0
            return 1
            ;;
    esac
}
