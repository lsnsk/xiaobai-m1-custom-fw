#!/bin/sh
# CGI API backend for Xiaobai M1 Local Russian Web Portal & OpenWrt Bot (/app/eye/www/cgi-bin/api.cgi)

. /app/eye/lib.sh
load_eye_conf

get_param() {
    printf "%s" "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1
}

json_escape() {
    printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' | tr -d '\r'
}

send_json() {
    printf "Content-Type: application/json; charset=utf-8\r\n"
    printf "Cache-Control: no-store, no-cache, must-revalidate\r\n\r\n"
    printf "%s\n" "$1"
}

restart_main_app_safe() {
    (
        sleep 1
        killall main_app 2>/dev/null || true
        _rw=0
        while pidof main_app >/dev/null 2>&1 && [ "$_rw" -lt 10 ]; do
            usleep 500000 2>/dev/null || sleep 1
            _rw=$((_rw + 1))
        done
        if pidof main_app >/dev/null 2>&1; then
            killall -9 main_app 2>/dev/null || true
            sleep 1
        fi
        cd /app/bin && ./main_app >> /tmp/main_app.log 2>&1 &
    ) >/dev/null 2>&1 &
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

emit_status_json() {
    BAT=$(get_battery_pct)
    BAT_V=$(get_battery_v)
    BAT_MV=$(get_battery_mv)
    IP=$(get_wlan_ip)
    SSID=$(get_nv "miio_ssid" "")
    RSSI=$(get_wifi_rssi)
    UP=$(get_uptime_s)
    NOW_STR=$(date '+%d.%m.%Y %H:%M:%S')
    UNTIL_S=$(cat /tmp/eye_wake_until 2>/dev/null || echo 0)
    WAKE_REM=$((UNTIL_S - UP))
    [ "$WAKE_REM" -lt 0 ] && WAKE_REM=0

    BAT_LIVE=false
    if is_battery_live; then
        BAT_LIVE=true
        save_bat_cache >/dev/null 2>&1 || true
    fi
    SD_INFO=$(get_sd_usage_str)

    PIR=$(get_nv "s_alarmSwitch" "1")
    STAY=$(get_nv "s_stayTime" "10")
    INTV=$(get_nv "s_videoInterval" "60")
    ECO=$(get_nv "s_powerSaveMode" "0")
    BSCR=$(get_nv "s_brightScreen" "0")
    SLPT=$(get_nv "sleep_time" "15")
    NIGHT=$(get_nv "s_night" "0")
    WDR=$(get_nv "s_wdr" "0")
    LDC=$(get_nv "s_distortionCorrection" "1")
    DBVOL=$(get_nv "doorbell_voice" "2")
    AREP="${AUTO_REPLY_SND:-off}"
    [ -z "$AREP" ] && AREP="off"
    AOB="${AUTO_REPLY_ONLY_BELL:-1}"
    PWAKE="${PING_WAKE:-0}"
    LBAT="${LOW_BAT_ALERT:-20}"
    DNDE="${DND_ENABLE:-0}"
    DND_ACT=false
    is_dnd_now && DND_ACT=true
    HAS_CV=false
    has_custom_voice && HAS_CV=true
    MQTTE="${MQTT_ENABLE:-0}"

    send_json "{\"ok\":true,\"bat\":\"$(json_escape "$BAT")\",\"bat_live\":$BAT_LIVE,\"bat_v\":\"$(json_escape "$BAT_V")\",\"bat_mv\":\"$(json_escape "$BAT_MV")\",\"ip\":\"$(json_escape "$IP")\",\"ssid\":\"$(json_escape "$SSID")\",\"rssi\":\"$(json_escape "$RSSI")\",\"sd\":\"$(json_escape "$SD_INFO")\",\"uptime\":$UP,\"time\":\"$(json_escape "$NOW_STR")\",\"wake_rem\":$WAKE_REM,\"vo_rotate\":\"${VO_ROTATE:-90}\",\"cam_rotate\":\"${CAM_ROTATE:-90}\",\"mi_cloud\":\"${MI_CLOUD_ENABLE:-0}\",\"keep_awake\":\"${KEEP_AWAKE_SEC:-35}\",\"speaker_vol\":\"${SPEAKER_VOL:-2}\",\"auto_reply\":\"$(json_escape "$AREP")\",\"auto_only_bell\":\"$(json_escape "$AOB")\",\"dnd\":\"$(json_escape "$DNDE")\",\"dnd_active\":$DND_ACT,\"dnd_hours\":\"${DND_START:-23}:00-${DND_END:-8}:00\",\"custom_voice\":$HAS_CV,\"mqtt_enable\":\"$(json_escape "$MQTTE")\",\"mqtt_host\":\"$(json_escape "${MQTT_HOST:-}")\",\"mqtt_port\":\"$(json_escape "${MQTT_PORT:-1883}")\",\"mqtt_user\":\"$(json_escape "${MQTT_USER:-}")\",\"mqtt_prefix\":\"$(json_escape "${MQTT_PREFIX:-xiaobai_m1}")\",\"mqtt_has_pass\":$( [ -n "${MQTT_PASS:-}" ] && echo true || echo false ),\"ping_wake\":\"$(json_escape "$PWAKE")\",\"low_bat\":\"$(json_escape "$LBAT")\",\"pir\":\"$(json_escape "$PIR")\",\"stay\":\"$(json_escape "$STAY")\",\"interval\":\"$(json_escape "$INTV")\",\"eco\":\"$(json_escape "$ECO")\",\"bscreen\":\"$(json_escape "$BSCR")\",\"sleep_time\":\"$(json_escape "$SLPT")\",\"night\":\"$(json_escape "$NIGHT")\",\"wdr\":\"$(json_escape "$WDR")\",\"ldc\":\"$(json_escape "$LDC")\",\"db_vol\":\"$(json_escape "$DBVOL")\",\"tz\":\"$(json_escape "${TZ:-MSK-3}")\"}"
}

ACTION=$(get_param "action")

case "$ACTION" in
    status)
        if [ "$(get_param "wake")" = "1" ] && [ ! -f /tmp/force_sleep_now ]; then
            extend_awake 20
        fi
        emit_status_json
        ;;

    set_hw)
        touch /tmp/eye_user_active
        extend_awake "${KEEP_AWAKE_SEC:-35}"
        KEY=$(get_param "key")
        VAL=$(get_param "val")
        case "$KEY" in
            pir)        case "$VAL" in 0|1) set_nv "s_alarmSwitch" "$VAL" ;; esac ;;
            stay)       is_uint "$VAL" && [ "$VAL" -le 60 ] && set_nv "s_stayTime" "$VAL" ;;
            interval)   is_uint "$VAL" && [ "$VAL" -le 600 ] && set_nv "s_videoInterval" "$VAL" ;;
            eco)        case "$VAL" in 0|1) set_nv "s_powerSaveMode" "$VAL" ;; esac ;;
            bscreen)    case "$VAL" in 0|1) set_nv "s_brightScreen" "$VAL" ;; esac ;;
            sleep_time) is_uint "$VAL" && [ "$VAL" -ge 5 ] && [ "$VAL" -le 600 ] && set_nv "sleep_time" "$VAL" ;;
            night)      case "$VAL" in 0|1|2) set_nv "s_night" "$VAL" ;; esac ;;
            wdr)        case "$VAL" in 0|1) set_nv "s_wdr" "$VAL" ;; esac ;;
            ldc)        case "$VAL" in 0|1) set_nv "s_distortionCorrection" "$VAL" ;; esac ;;
            db_vol)     case "$VAL" in 0|1|2|3) set_nv "doorbell_voice" "$VAL"; apply_dnd_ram ;; esac ;;
            keep_awake)
                if is_uint "$VAL" && [ "$VAL" -ge 10 ] && [ "$VAL" -le 300 ]; then
                    set_conf_kv "KEEP_AWAKE_SEC" "$VAL"
                    extend_awake "$VAL"
                fi
                ;;
            speaker_vol)
                case "$VAL" in 1|2) set_conf_kv "SPEAKER_VOL" "$VAL" ;; esac
                ;;
            auto_reply)
                case "$VAL" in
                    ''|off) set_conf_kv "AUTO_REPLY_SND" "" ;;
                    *[!A-Za-z0-9_-]*) ;;
                    *) set_conf_kv "AUTO_REPLY_SND" "$VAL" ;;
                esac
                ;;
            auto_only_bell)
                case "$VAL" in 0|1) set_conf_kv "AUTO_REPLY_ONLY_BELL" "$VAL" ;; esac
                ;;
            dnd)
                case "$VAL" in 0|1) set_conf_kv "DND_ENABLE" "$VAL"; apply_dnd_ram ;; esac
                ;;
            tz)
                case "$VAL" in
                    ''|*[!A-Za-z0-9:+_-]*) ;;
                    *)
                        set_conf_kv "TZ" "$VAL"
                        sync_rtc_and_osd
                        apply_dnd_ram
                        ;;
                esac
                ;;
            ping_wake)
                case "$VAL" in 0|1) set_conf_kv "PING_WAKE" "$VAL"; apply_wowlan ;; esac
                ;;
            low_bat)
                if is_uint "$VAL" && [ "$VAL" -le 50 ]; then
                    set_conf_kv "LOW_BAT_ALERT" "$VAL"
                    set_nv "s_lowBattery" "$VAL"
                fi
                ;;
            mqtt_enable)
                case "$VAL" in
                    0|1)
                        set_conf_kv "MQTT_ENABLE" "$VAL"
                        rm -f /tmp/mqtt_disc_sent /tmp/mqtt_unreachable /app/sd/.mqtt_disc_v4_* 2>/dev/null || true
                        ;;
                esac
                ;;
            rot)
                case "$VAL" in
                    0|90|180|270)
                        OLD_VO="${VO_ROTATE:-90}"
                        set_cam_and_vo_rotate "$VAL"
                        if [ "$OLD_VO" != "${VO_ROTATE:-90}" ]; then
                            restart_main_app_safe
                        fi
                        ;;
                esac
                ;;
            *)
                send_json "{\"ok\":false,\"error\":\"Неизвестный параметр\"}"
                exit 0
                ;;
        esac
        emit_status_json
        ;;

    snap)
        touch /tmp/eye_user_active
        extend_awake "${KEEP_AWAKE_SEC:-35}"
        if /app/bin/eye_snap /tmp/web_snap.jpg "${CAM_ROTATE:-90}" 3500; then
            send_mqtt_snapshot /tmp/web_snap.jpg "live"
            TS=$(date +%s)
            send_json "{\"ok\":true,\"url\":\"/live.jpg?t=$TS\"}"
        else
            send_json "{\"ok\":false,\"error\":\"Не удалось получить кадр (убедитесь, что камера активна)\"}"
        fi
        ;;

    record)
        touch /tmp/eye_user_active
        DUR=$(get_param "sec")
        case "$DUR" in ''|*[!0-9]*) DUR=10 ;; esac
        [ "$DUR" -lt 3 ] && DUR=3
        [ "$DUR" -gt 30 ] && DUR=30
        extend_awake $((DUR + 45))
        /app/eye/ui_action.sh record "$DUR" >/dev/null 2>&1 &
        send_json "{\"ok\":true,\"sec\":$DUR}"
        ;;

    say)
        touch /tmp/eye_user_active
        SND=$(get_param "snd")
        VOL=$(get_param "vol")
        extend_awake "${KEEP_AWAKE_SEC:-35}"
        case "$SND" in
            ''|*[!A-Za-z0-9_-]*)
                send_json "{\"ok\":false,\"error\":\"Некорректное имя аудиофайла\"}"
                exit 0
                ;;
        esac
        if play_fastreply "$SND" "$VOL"; then
            send_json "{\"ok\":true,\"snd\":\"$(json_escape "$SND")\"}"
        else
            send_json "{\"ok\":false,\"error\":\"Аудиофайл не найден\"}"
        fi
        ;;

    speak)
        touch /tmp/eye_user_active
        extend_awake 45
        SAVE=$(get_param "save")
        VOL=$(get_param "vol")
        CLEN="${CONTENT_LENGTH:-0}"
        case "$CLEN" in ''|*[!0-9]*) CLEN=0 ;; esac
        if [ "$CLEN" -ge 320 ] && [ "$CLEN" -le 262144 ]; then
            mkdir -p /tmp/sound
            if /app/bin/eye_tool stdin2file /tmp/sound/ptt_live "$CLEN"; then
                chmod 755 /tmp/sound/ptt_live 2>/dev/null || true
                if [ "$SAVE" = "1" ]; then
                    ensure_sd_mounted
                    mkdir -p /app/sd/voices 2>/dev/null || true
                    cp /tmp/sound/ptt_live /app/sd/voices/05_custom 2>/dev/null || cp /tmp/sound/ptt_live /tmp/sound/05_custom 2>/dev/null || true
                    sync
                    sync_custom_voices
                fi
                play_fastreply "ptt_live" "$VOL"
                send_json "{\"ok\":true,\"bytes\":$CLEN,\"saved\":$( [ "$SAVE" = "1" ] && echo true || echo false )}"
            else
                send_json "{\"ok\":false,\"error\":\"Ошибка приёма аудиоданных\"}"
            fi
        else
            send_json "{\"ok\":false,\"error\":\"Некорректный размер аудио (от 0.1 до 32 сек)\"}"
        fi
        ;;

    speak_ogg)
        touch /tmp/eye_user_active
        extend_awake 45
        SAVE=$(get_param "save")
        VOL=$(get_param "vol")
        CLEN="${CONTENT_LENGTH:-0}"
        case "$CLEN" in ''|*[!0-9]*) CLEN=0 ;; esac
        if [ "$CLEN" -ge 32 ] && [ "$CLEN" -le 524288 ]; then
            mkdir -p /tmp/sound
            if /app/bin/eye_tool stdin2file /tmp/tg_voice.oga "$CLEN" && \
               /app/bin/eye_tool ogg2alaw /tmp/tg_voice.oga /tmp/sound/ptt_live; then
                rm -f /tmp/tg_voice.oga
                chmod 755 /tmp/sound/ptt_live 2>/dev/null || true
                if [ "$SAVE" = "1" ]; then
                    ensure_sd_mounted
                    mkdir -p /app/sd/voices 2>/dev/null || true
                    cp /tmp/sound/ptt_live /app/sd/voices/05_custom 2>/dev/null || cp /tmp/sound/ptt_live /tmp/sound/05_custom 2>/dev/null || true
                    sync
                    sync_custom_voices
                fi
                play_fastreply "ptt_live" "$VOL"
                ALAW_SZ=$(wc -c < /tmp/sound/ptt_live 2>/dev/null | tr -cd '0-9')
                [ -z "$ALAW_SZ" ] && ALAW_SZ=8000
                SEC=$(( (ALAW_SZ + 4000) / 8000 ))
                [ "$SEC" -lt 1 ] && SEC=1
                send_json "{\"ok\":true,\"sec\":$SEC,\"bytes\":$ALAW_SZ,\"saved\":$( [ "$SAVE" = "1" ] && echo true || echo false )}"
            else
                rm -f /tmp/tg_voice.oga
                send_json "{\"ok\":false,\"error\":\"Ошибка декодирования голосового файла Opus/WAV\"}"
            fi
        else
            send_json "{\"ok\":false,\"error\":\"Некорректный размер голосового сообщения\"}"
        fi
        ;;

    save_last_ptt)
        touch /tmp/eye_user_active
        extend_awake "${KEEP_AWAKE_SEC:-35}"
        if [ -s /tmp/sound/ptt_live ]; then
            ensure_sd_mounted
            mkdir -p /app/sd/voices 2>/dev/null || true
            cp /tmp/sound/ptt_live /app/sd/voices/05_custom 2>/dev/null || cp /tmp/sound/ptt_live /tmp/sound/05_custom 2>/dev/null || true
            sync
            sync_custom_voices
            send_json "{\"ok\":true}"
        else
            send_json "{\"ok\":false,\"error\":\"Нет свежей голосовой записи в памяти\"}"
        fi
        ;;

    del_custom_voice)
        touch /tmp/eye_user_active
        ensure_sd_mounted
        rm -f /app/sd/voices/05_custom /tmp/sound/05_custom 2>/dev/null || true
        if [ "${AUTO_REPLY_SND:-}" = "05_custom" ]; then
            set_conf_kv "AUTO_REPLY_SND" ""
        fi
        sync
        emit_status_json
        ;;

    awake)
        touch /tmp/eye_user_active
        SEC=$(get_param "sec")
        extend_awake "${SEC:-60}"
        send_json "{\"ok\":true}"
        ;;

    sleep)
        release_awake_now
        send_json "{\"ok\":true}"
        ;;

    list)
        touch /tmp/eye_user_active
        extend_awake "${KEEP_AWAKE_SEC:-35}"
        LIMIT=$(get_param "limit")
        case "$LIMIT" in
            ''|*[!0-9]*) LIMIT=36 ;;
        esac
        [ "$LIMIT" -lt 1 ] && LIMIT=6
        [ "$LIMIT" -gt 100 ] && LIMIT=100
        printf "Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n["
        FIRST=1
        if [ -d /app/sd/MIJIA_RECORD_VIDEO ]; then
            for MP4 in $(find /app/sd/MIJIA_RECORD_VIDEO -name "*.mp4" 2>/dev/null | sort -r | head -n "$LIMIT"); do
                REL="${MP4#/app/sd/MIJIA_RECORD_VIDEO/}"
                JPG_REL="${REL%.mp4}.jpeg"
                [ -f "/app/sd/MIJIA_RECORD_VIDEO/$JPG_REL" ] || JPG_REL=""
                SZ_KB=$(du -k "$MP4" 2>/dev/null | awk '{print $1}')
                [ -z "$SZ_KB" ] && SZ_KB=0
                LBL=$(format_clip_label "$REL")
                [ "$FIRST" -eq 0 ] && printf ","
                FIRST=0
                printf "{\"rel\":\"%s\",\"label\":\"%s\",\"mp4\":\"/sd/%s\",\"jpg\":\"%s\",\"size_kb\":%s}" \
                    "$(json_escape "$REL")" \
                    "$(json_escape "$LBL")" \
                    "$(json_escape "$REL")" \
                    "$( [ -n "$JPG_REL" ] && printf "/sd/%s" "$(json_escape "$JPG_REL")" )" \
                    "$SZ_KB"
            done
        fi
        printf "]\n"
        ;;

    snaps)
        touch /tmp/eye_user_active
        extend_awake "${KEEP_AWAKE_SEC:-35}"
        LIMIT=$(get_param "limit")
        case "$LIMIT" in ''|*[!0-9]*) LIMIT=12 ;; esac
        [ "$LIMIT" -lt 1 ] && LIMIT=6
        [ "$LIMIT" -gt 48 ] && LIMIT=48
        printf "Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n["
        FIRST=1
        if [ -d /app/sd/snapshots ]; then
            for JPG in $(find /app/sd/snapshots -maxdepth 1 -type f -name "*.jpg" 2>/dev/null | sort -r | head -n "$LIMIT"); do
                BN=$(basename "$JPG")
                SZ_KB=$(du -k "$JPG" 2>/dev/null | awk '{print $1}')
                [ -z "$SZ_KB" ] && SZ_KB=0
                [ "$FIRST" -eq 0 ] && printf ","
                FIRST=0
                printf "{\"name\":\"%s\",\"url\":\"/snapshots/%s\",\"size_kb\":%s}" \
                    "$(json_escape "$BN")" "$(json_escape "$BN")" "$SZ_KB"
            done
        fi
        printf "]\n"
        ;;

    get_conf)
        extend_awake "${KEEP_AWAKE_SEC:-35}"
        printf "Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n"
        CONF=$(find_eye_conf)
        if [ -n "$CONF" ] && [ -f "$CONF" ]; then
            cat "$CONF"
        elif [ -f /app/sd/eye.conf.example ]; then
            cat /app/sd/eye.conf.example
        else
            cat /app/eye/eye.conf.default
        fi
        ;;

    save_conf)
        touch /tmp/eye_user_active
        extend_awake 60
        ensure_sd_mounted
        if [ "${CONTENT_LENGTH:-0}" -gt 0 ] && [ "${CONTENT_LENGTH:-0}" -lt 32768 ]; then
            if /app/bin/eye_tool stdin2file /tmp/eye.conf.raw "$CONTENT_LENGTH"; then
                tr -d '\r' < /tmp/eye.conf.raw > /tmp/eye.conf.new
                rm -f /tmp/eye.conf.raw
                if ! sh -n /tmp/eye.conf.new >/dev/null 2>&1; then
                    rm -f /tmp/eye.conf.new
                    send_json "{\"ok\":false,\"error\":\"Синтаксическая ошибка в eye.conf (проверьте кавычки)\"}"
                elif cp -f /tmp/eye.conf.new "/app/sd/.eye.conf.tmp.$$" 2>/dev/null && \
                     mv -f "/app/sd/.eye.conf.tmp.$$" /app/sd/eye.conf 2>/dev/null; then
                    rm -f /tmp/eye.conf.new
                    rm -f /tmp/mqtt_disc_sent /tmp/mqtt_unreachable /app/sd/.mqtt_disc_v4_* 2>/dev/null || true
                    sync
                    OLD_VO="${VO_ROTATE:-90}"
                    OLD_TZ="${TZ:-MSK-3}"
                    /app/eye/eye_early_init.sh >/dev/null 2>&1
                    load_eye_conf
                    apply_wowlan
                    if [ "$OLD_TZ" != "${TZ:-MSK-3}" ]; then
                        sync_rtc_and_osd >/dev/null 2>&1 || true
                        apply_dnd_ram
                    fi
                    RESTART_UI=$(get_param "restart_ui")
                    if [ "$RESTART_UI" = "1" ] || [ "$OLD_VO" != "${VO_ROTATE:-90}" ]; then
                        restart_main_app_safe
                    fi
                    send_json "{\"ok\":true}"
                else
                    rm -f /tmp/eye.conf.new "/app/sd/.eye.conf.tmp.$$"
                    send_json "{\"ok\":false,\"error\":\"Ошибка записи на карту памяти /app/sd/eye.conf\"}"
                fi
            else
                send_json "{\"ok\":false,\"error\":\"Ошибка чтения тела запроса\"}"
            fi
        else
            send_json "{\"ok\":false,\"error\":\"Пустой запрос\"}"
        fi
        ;;

    save_mqtt)
        touch /tmp/eye_user_active
        extend_awake 60
        ensure_sd_mounted
        CLEN="${CONTENT_LENGTH:-0}"
        case "$CLEN" in ''|*[!0-9]*) CLEN=0 ;; esac
        if [ "$CLEN" -gt 0 ] && [ "$CLEN" -le 4096 ]; then
            if /app/bin/eye_tool stdin2file /tmp/mqtt_cfg.raw "$CLEN"; then
                tr -d '\r' < /tmp/mqtt_cfg.raw > /tmp/mqtt_cfg.clean
                rm -f /tmp/mqtt_cfg.raw
                _m_en="${MQTT_ENABLE:-0}"
                _m_host="${MQTT_HOST:-}"
                _m_port="${MQTT_PORT:-1883}"
                _m_user="${MQTT_USER:-}"
                _m_pfx="${MQTT_PREFIX:-xiaobai_m1}"
                _m_pass=""
                _m_keep="1"
                while IFS= read -r _mln || [ -n "$_mln" ]; do
                    case "$_mln" in
                        MQTT_ENABLE=*)    _m_en="${_mln#MQTT_ENABLE=}" ;;
                        MQTT_HOST=*)      _m_host="${_mln#MQTT_HOST=}" ;;
                        MQTT_PORT=*)      _m_port="${_mln#MQTT_PORT=}" ;;
                        MQTT_USER=*)      _m_user="${_mln#MQTT_USER=}" ;;
                        MQTT_PREFIX=*)    _m_pfx="${_mln#MQTT_PREFIX=}" ;;
                        MQTT_PASS=*)      _m_pass="${_mln#MQTT_PASS=}" ;;
                        MQTT_PASS_KEEP=*) _m_keep="${_mln#MQTT_PASS_KEEP=}" ;;
                    esac
                done < /tmp/mqtt_cfg.clean
                rm -f /tmp/mqtt_cfg.clean
                case "$_m_en" in 1) _m_en="1" ;; *) _m_en="0" ;; esac
                case "$_m_port" in ''|*[!0-9]*) _m_port="1883" ;; esac
                if [ "$_m_port" -lt 1 ] || [ "$_m_port" -gt 65535 ]; then _m_port="1883"; fi
                [ -z "$_m_pfx" ] && _m_pfx="xiaobai_m1"
                set_conf_kv "MQTT_ENABLE" "$_m_en"
                set_conf_kv "MQTT_HOST" "$_m_host"
                set_conf_kv "MQTT_PORT" "$_m_port"
                set_conf_kv "MQTT_USER" "$_m_user"
                set_conf_kv "MQTT_PREFIX" "$_m_pfx"
                if [ "$_m_keep" != "1" ] || [ -n "$_m_pass" ]; then
                    set_conf_kv "MQTT_PASS" "$_m_pass"
                fi
                rm -f /tmp/mqtt_disc_sent /tmp/mqtt_unreachable /app/sd/.mqtt_disc_v4_* 2>/dev/null || true
                emit_status_json
            else
                send_json "{\"ok\":false,\"error\":\"Ошибка чтения настроек MQTT\"}"
            fi
        else
            send_json "{\"ok\":false,\"error\":\"Пустой запрос MQTT\"}"
        fi
        ;;

    mqtt_test)
        touch /tmp/eye_user_active
        extend_awake 45
        rm -f /tmp/mqtt_unreachable /tmp/mqtt_disc_sent /app/sd/.mqtt_disc_v4_* 2>/dev/null || true
        if [ -z "${MQTT_HOST:-}" ]; then
            send_json "{\"ok\":false,\"error\":\"Укажите адрес MQTT-брокера (например 192.168.1.10) и сохраните настройки!\"}"
        else
            _mp="${MQTT_PORT:-1883}"
            _mpfx="${MQTT_PREFIX:-xiaobai_m1}"
            _mh_esc=$(json_escape "$MQTT_HOST")
            /app/bin/eye_tool mqttpub "$MQTT_HOST" "$_mp" "${_mpfx}/availability" "online" "${MQTT_USER:-}" "${MQTT_PASS:-}" 1 2>/tmp/mqtt_err.txt
            _mrc=$?
            _merr=$(cat /tmp/mqtt_err.txt 2>/dev/null || true)
            rm -f /tmp/mqtt_err.txt
            if [ "$_mrc" -eq 0 ]; then
                rm -f /tmp/mqtt_unreachable
                rm -f /tmp/mqtt_snap.jpg
                if /app/bin/eye_snap /tmp/mqtt_snap.jpg "${CAM_ROTATE:-90}" 3000 >/dev/null 2>&1 && [ -s /tmp/mqtt_snap.jpg ]; then
                    cp -f /tmp/mqtt_snap.jpg /tmp/web_snap.jpg 2>/dev/null || true
                    rm -f /tmp/mqtt_snap.jpg
                    cache_last_snap /tmp/web_snap.jpg
                    _snap_src="/tmp/web_snap.jpg"
                else
                    rm -f /tmp/mqtt_snap.jpg
                    _snap_src=$(get_mqtt_fallback_snap || true)
                fi
                if mqtt_ensure_discovery; then
                    _saved_en="${MQTT_ENABLE:-0}"
                    MQTT_ENABLE=1
                    send_mqtt_telemetry_sync "awake" >/dev/null 2>&1 || true
                    if [ -n "$_snap_src" ] && [ -s "$_snap_src" ]; then
                        mqtt_run_pub_file "${_mpfx}/snapshot" "$_snap_src" 1 || true
                    fi
                    MQTT_ENABLE="$_saved_en"
                    send_json "{\"ok\":true,\"msg\":\"Успешно! Устройство и камера добавлены в Home Assistant (MQTT Discovery)\"}"
                else
                    send_json "{\"ok\":false,\"error\":\"Подключено к ${_mh_esc}:${_mp}, но ошибка публикации Auto-Discovery\"}"
                fi
            elif [ "$_mrc" -eq 2 ]; then
                case "$_merr" in
                    *MQTT_CONNACK_RC=4*|*MQTT_CONNACK_RC=5*)
                        send_json "{\"ok\":false,\"error\":\"Mosquitto (${_mh_esc}:${_mp}) требует логин и пароль — укажите MQTT_USER и MQTT_PASS!\"}"
                        ;;
                    *)
                        send_json "{\"ok\":false,\"error\":\"Брокер ${_mh_esc}:${_mp} отклонил подключение ($(json_escape "$_merr"))\"}"
                        ;;
                esac
            else
                send_json "{\"ok\":false,\"error\":\"Не удалось подключиться к ${_mh_esc}:${_mp} (проверьте IP и порт Mosquitto)\"}"
            fi
        fi
        ;;

    tg_test)
        touch /tmp/eye_user_active
        extend_awake 45
        if [ -z "$TG_BOT_TOKEN" ]; then
            send_json "{\"ok\":false,\"error\":\"Сначала укажите TG_BOT_TOKEN в настройках и сохраните!\"}"
        elif [ -z "$TG_CHAT_ID" ]; then
            _api="${TG_API_URL:-https://api.telegram.org}/bot${TG_BOT_TOKEN}"
            _upd=$(tg_curl -G "${_api}/getUpdates" -d "limit=5" 2>/dev/null | tr -d '\r\n')
            _found=$(printf "%s" "$_upd" | sed -n 's/.*"chat":{"id":\([-0-9][0-9]*\).*/\1/p')
            if [ -n "$_found" ]; then
                send_json "{\"ok\":false,\"error\":\"Укажите TG_CHAT_ID и сохраните! Найден чат бота: ${_found}\"}"
            else
                send_json "{\"ok\":false,\"error\":\"Укажите TG_CHAT_ID (или добавьте бота в семейную группу, напишите там сообщение и нажмите эту кнопку снова, чтобы увидеть ID)!\"}"
            fi
        else
            RES=$(/app/eye/tg_notify.sh --test 2>&1)
            if printf "%s" "$RES" | grep -q '"ok":true'; then
                send_json "{\"ok\":true}"
            else
                send_json "{\"ok\":false,\"error\":\"$(json_escape "$RES")\"}"
            fi
        fi
        ;;

    reboot)
        (sleep 1; mark_clean_reboot; /app/bin/recovery 0 >/dev/null 2>&1; sync; reboot -f) >/dev/null 2>&1 &
        send_json "{\"ok\":true}"
        ;;

    *)
        send_json "{\"ok\":false,\"error\":\"Неизвестная команда\"}"
        ;;
esac
