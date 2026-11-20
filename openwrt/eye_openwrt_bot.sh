#!/bin/sh
# 24/7 OpenWrt Companion Bot for Xiaomi Xiaobai Smart Cat Eye M1
# Modern button-driven Telegram UI (Bot API 9.4+/10.1+ button styles, zero slash commands)
# Wakes sleeping peephole via UDP WoWLAN magic packet (< 1 mA sleep) and controls all settings!

CONF_FILE="${1:-/etc/eye-bot.conf}"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ] || [ -z "$EYE_IP" ]; then
    echo "eye-bot: Заполните TG_BOT_TOKEN, TG_CHAT_ID и EYE_IP в $CONF_FILE" >&2
    sleep 10
    exit 1
fi

API_BASE="${TG_API_URL:-https://api.telegram.org}/bot${TG_BOT_TOKEN}"
FILE_BASE="${TG_API_URL:-https://api.telegram.org}/file/bot${TG_BOT_TOKEN}"
EYE_URL="http://${EYE_IP}:${EYE_WEB_PORT:-8080}"
WOWLAN_PORT="${WOWLAN_PORT:-9999}"
WOWLAN_KEY="${WOWLAN_KEY:-WAKEUP}"
EYE_BROADCAST="${EYE_BROADCAST:-255.255.255.255}"
WAKE_TIMEOUT_SEC="${WAKE_TIMEOUT_SEC:-14}"
CACHE_JSON="/tmp/eye_last_status.json"
CLIPS_CACHE="/tmp/eye_openwrt_clips.json"
BAT_FILE="/etc/eye-bot.bat"
WAKE_FAIL_STAMP="/tmp/eye_wake_fail_ts"

tg_chat_list() {
    printf "%s" "$TG_CHAT_ID" | tr ',;' '  '
}

tg_primary_chat() {
    for _c in $(tg_chat_list); do
        echo "$_c"
        return 0
    done
}

is_chat_allowed() {
    [ -n "$1" ] || return 1
    for _cid in $(tg_chat_list); do
        [ "$_cid" = "$1" ] && return 0
    done
    return 1
}

REPLY_CHAT_ID="$(tg_primary_chat)"

REPLY_KB='{"keyboard":[[{"text":"🎛 Пульт глазка","style":"primary"},{"text":"📸 Живое фото"}],[{"text":"🔊 Ответить у двери"},{"text":"💤 В сон"}]],"resize_keyboard":true,"is_persistent":true,"input_field_placeholder":"🎙 Запишите голосовое за дверь или нажмите кнопку…"}'

VOICE_SENT_KB='{"inline_keyboard":[[{"text":"🔁 Повторить за дверью","callback_data":"say:ptt_live","style":"primary"},{"text":"📸 Живое фото","callback_data":"act:snap","style":"primary"}],[{"text":"💾 Сохранить как «Свою фразу»","callback_data":"act:save_ptt","style":"success"}],[{"text":"🎛 Пульт глазка","callback_data":"menu:open"},{"text":"💤 В сон","callback_data":"act:sleep"}]]}'

CLIP_KB='{"inline_keyboard":[[{"text":"🎞 Видеоархив","callback_data":"menu:open_clips","style":"primary"},{"text":"🎛 Пульт глазка","callback_data":"menu:open"}]]}'

tg_curl() {
    if [ -n "$TG_PROXY" ]; then
        curl -s -k --connect-timeout 10 --max-time 45 -x "$TG_PROXY" "$@"
    elif [ -n "$TG_INTERFACE" ]; then
        # Send Telegram traffic out of a specific interface (e.g. WireGuard tunnel wg0) when direct access is blocked
        curl -s -k --connect-timeout 10 --max-time 45 --interface "$TG_INTERFACE" "$@"
    else
        curl -s -k --connect-timeout 10 --max-time 45 "$@"
    fi
}

eye_curl() {
    curl -s --connect-timeout 2 --max-time 12 "$@"
}

cycle_next() {
    _cur="$1"
    shift
    _first="$1"
    while [ $# -gt 0 ]; do
        if [ "$1" = "$_cur" ]; then
            shift
            if [ $# -gt 0 ]; then echo "$1"; else echo "$_first"; fi
            return 0
        fi
        shift
    done
    echo "$_first"
}

auto_reply_title() {
    case "$1" in
        04_fastreply) echo "Доставку у двери" ;;
        03_fastreply) echo "Сейчас открою" ;;
        01_fastreply) echo "Кто вы?" ;;
        02_fastreply) echo "Ведётся запись!" ;;
        05_custom)    echo "Своя фраза" ;;
        *)            echo "Выкл" ;;
    esac
}

night_title() {
    case "$1" in
        1) echo "Выкл" ;;
        2) echo "Всегда ВКЛ" ;;
        *) echo "Авто" ;;
    esac
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

send_udp_packet() {
    _dst="$1"
    if command -v socat >/dev/null 2>&1; then
        printf "%s" "$WOWLAN_KEY" | socat -T 1 - "UDP4-DATAGRAM:${_dst}:${WOWLAN_PORT},broadcast" 2>/dev/null
    elif command -v nc >/dev/null 2>&1; then
        printf "%s" "$WOWLAN_KEY" | nc -u -w 1 "$_dst" "$WOWLAN_PORT" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1); s.settimeout(0.8); s.sendto(b'$WOWLAN_KEY',('$_dst',$WOWLAN_PORT)); print(s.recv(64).decode('utf-8','ignore'))" 2>/dev/null
    fi
}

ensure_arp_neighbor() {
    if [ -n "${EYE_MAC:-}" ] && command -v ip >/dev/null 2>&1; then
        ip neigh replace "$EYE_IP" lladdr "$EYE_MAC" nud permanent dev "${EYE_IFACE:-br-lan}" 2>/dev/null || true
    fi
}

json_set_str() {
    awk -v k="$1" -v v="$2" '
    {
        pat = "\"" k "\":\""
        p = index($0, pat)
        if (p > 0) {
            pre = substr($0, 1, p + length(pat) - 1)
            rest = substr($0, p + length(pat))
            q = index(rest, "\"")
            if (q > 0) {
                print pre v substr(rest, q)
                next
            }
        }
        print
    }'
}

get_cached_bat() {
    _cb=""
    [ -f "$CACHE_JSON" ] && _cb=$(jsonfilter -i "$CACHE_JSON" -e '@.bat' 2>/dev/null)
    case "$_cb" in
        ''|*[!0-9]*)
            [ -f "$BAT_FILE" ] && _cb=$(cat "$BAT_FILE" 2>/dev/null | tr -cd '0-9')
            ;;
    esac
    printf "%s" "$_cb"
}

load_offline_status_json() {
    if [ -f "$CACHE_JSON" ]; then
        STATUS_JSON=$(cat "$CACHE_JSON" 2>/dev/null)
    elif [ -f "$BAT_FILE" ]; then
        _fb=$(cat "$BAT_FILE" 2>/dev/null | tr -cd '0-9')
        STATUS_JSON="{\"bat\":\"${_fb:-?}\"}"
    else
        STATUS_JSON='{}'
    fi
}

save_status_cache() {
    _raw="$1"
    _nbat=$(printf "%s" "$_raw" | jsonfilter -e '@.bat' 2>/dev/null)
    _nbat_v=$(printf "%s" "$_raw" | jsonfilter -e '@.bat_v' 2>/dev/null)
    _nbat_mv=$(printf "%s" "$_raw" | jsonfilter -e '@.bat_mv' 2>/dev/null)
    _nsd=$(printf "%s" "$_raw" | jsonfilter -e '@.sd' 2>/dev/null)

    case "$_nbat" in
        ''|*[!0-9]*)
            _pbat=$(get_cached_bat)
            if [ -n "$_pbat" ]; then
                _raw=$(printf "%s" "$_raw" | json_set_str bat "$_pbat")
                if [ -f "$CACHE_JSON" ]; then
                    _pbv=$(jsonfilter -i "$CACHE_JSON" -e '@.bat_v' 2>/dev/null)
                    _pbmv=$(jsonfilter -i "$CACHE_JSON" -e '@.bat_mv' 2>/dev/null)
                    [ -z "$_nbat_v" ] && [ -n "$_pbv" ] && _raw=$(printf "%s" "$_raw" | json_set_str bat_v "$_pbv")
                    [ -z "$_nbat_mv" ] && [ -n "$_pbmv" ] && _raw=$(printf "%s" "$_raw" | json_set_str bat_mv "$_pbmv")
                fi
            fi
            ;;
        *)
            _prev_bf=""
            [ -f "$BAT_FILE" ] && _prev_bf=$(cat "$BAT_FILE" 2>/dev/null | tr -cd '0-9')
            if [ "$_prev_bf" != "$_nbat" ]; then
                printf "%s\n" "$_nbat" > "${BAT_FILE}.tmp" 2>/dev/null && \
                    mv -f "${BAT_FILE}.tmp" "$BAT_FILE" 2>/dev/null || true
            fi
            ;;
    esac

    case "$_nsd" in
        ""|"Монтируется..."|"Не смонтирована"|7.9M*)
            if [ -f "$CACHE_JSON" ]; then
                _psd=$(jsonfilter -i "$CACHE_JSON" -e '@.sd' 2>/dev/null)
                case "$_psd" in
                    ""|"Монтируется..."|"Не смонтирована"|7.9M*) ;;
                    *) _raw=$(printf "%s" "$_raw" | json_set_str sd "$_psd") ;;
                esac
            fi
            ;;
    esac

    printf "%s" "$_raw" > "${CACHE_JSON}.tmp" 2>/dev/null && mv -f "${CACHE_JSON}.tmp" "$CACHE_JSON"
}

fetch_live_status() {
    _q="action=status"
    [ "$1" = "wake" ] && _q="action=status&wake=1"
    _st=$(eye_curl "${EYE_URL}/cgi-bin/api.cgi?${_q}")
    if printf "%s" "$_st" | grep -q '"ok":true'; then
        rm -f "$WAKE_FAIL_STAMP"
        save_status_cache "$_st"
        EYE_ONLINE=1
        STATUS_JSON=$(cat "$CACHE_JSON" 2>/dev/null || printf "%s" "$_st")
        return 0
    fi
    EYE_ONLINE=0
    load_offline_status_json
    return 1
}

wake_eye() {
    _wmode="$1"
    ensure_arp_neighbor
    if fetch_live_status wake; then
        return 0
    fi
    if [ "$_wmode" != "force" ] && [ -f "$WAKE_FAIL_STAMP" ]; then
        _fts=$(cat "$WAKE_FAIL_STAMP" 2>/dev/null || echo 0)
        _now_ts=$(date +%s 2>/dev/null || echo 0)
        case "$_fts" in ''|*[!0-9]*) _fts=0 ;; esac
        if [ "$_now_ts" -ge "$_fts" ] && [ $((_now_ts - _fts)) -lt 15 ]; then
            logger -t eye-bot "wake_cooldown_skip age=$((_now_ts - _fts))s"
            return 1
        fi
    fi
    _wsec="${WAKE_TIMEOUT_SEC:-14}"
    case "$_wsec" in ''|*[!0-9]*) _wsec=14 ;; esac
    [ "$_wsec" -lt 4 ] && _wsec=4
    _deadline=$(( $(date +%s 2>/dev/null || echo 0) + _wsec ))
    _tries=0
    while [ "$_tries" -lt 12 ]; do
        send_udp_packet "$EYE_BROADCAST" >/dev/null 2>&1 &
        _ack=$(send_udp_packet "$EYE_IP")
        if printf "%s" "$_ack" | grep -q "OK_AWAKE"; then
            fetch_live_status wake && return 0
            sleep 1
            fetch_live_status wake && return 0
        fi
        if fetch_live_status wake; then
            return 0
        fi
        _cur_ts=$(date +%s 2>/dev/null || echo 0)
        [ "$_cur_ts" -ge "$_deadline" ] && break
        sleep 1
        _tries=$((_tries + 1))
    done
    if fetch_live_status wake; then
        return 0
    fi
    date +%s > "$WAKE_FAIL_STAMP" 2>/dev/null || true
    return 1
}

jf() {
    _v=$(printf "%s" "$STATUS_JSON" | jsonfilter -e "@.$1" 2>/dev/null)
    if [ -n "$_v" ]; then echo "$_v"; else echo "$2"; fi
}

build_photo_kb() {
    if [ "$(jf custom_voice false)" = "true" ]; then
        echo '{"inline_keyboard":[[{"text":"🏃 Сейчас открою","callback_data":"say:03_fastreply","style":"primary"},{"text":"🛍 Доставку у двери","callback_data":"say:04_fastreply","style":"primary"}],[{"text":"🗣 Своя фраза","callback_data":"say:05_custom","style":"success"},{"text":"❓ Кто вы?","callback_data":"say:01_fastreply"}],[{"text":"📹 Ведётся запись!","callback_data":"say:02_fastreply"},{"text":"📸 Ещё фото","callback_data":"act:snap"}],[{"text":"🎛 Пульт глазка","callback_data":"menu:open"},{"text":"💤 В сон","callback_data":"act:sleep"}]]}'
    else
        echo '{"inline_keyboard":[[{"text":"🏃 Сейчас открою","callback_data":"say:03_fastreply","style":"primary"},{"text":"🛍 Доставку у двери","callback_data":"say:04_fastreply","style":"primary"}],[{"text":"❓ Кто вы?","callback_data":"say:01_fastreply"},{"text":"📹 Ведётся запись!","callback_data":"say:02_fastreply"}],[{"text":"📸 Ещё фото","callback_data":"act:snap"},{"text":"🎛 Пульт глазка","callback_data":"menu:open"}]]}'
    fi
}

answer_cb() {
    [ -n "$1" ] || return 0
    tg_curl -X POST "${API_BASE}/answerCallbackQuery" \
        --data-urlencode "callback_query_id=$1" \
        --data-urlencode "text=$2" >/dev/null 2>&1 &
}

ensure_reply_menu() {
    _dst="${1:-${REPLY_CHAT_ID:-$(tg_primary_chat)}}"
    _stamp="/tmp/eye_bot_menu_$(printf "%s" "$_dst" | tr -cd '0-9-')"
    [ -f "$_stamp" ] && return 0
    tg_curl -X POST "${API_BASE}/sendMessage" \
        --data-urlencode "chat_id=${_dst}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=🎛 <b>Пульт умного глазка M1 готов (24/7)</b> — кнопки быстрого доступа закреплены внизу экрана" \
        --data-urlencode "reply_markup=${REPLY_KB}" >/dev/null 2>&1
    touch "$_stamp" 2>/dev/null || true
}

init_bot_menu() {
    tg_curl -X POST "${API_BASE}/setMyCommands" \
        --data-urlencode 'commands=[{"command":"menu","description":"🎛 Открыть пульт глазка"}]' >/dev/null 2>&1
    if [ ! -f /etc/eye-bot.menu_sent ]; then
        for _cid in $(tg_chat_list); do
            ensure_reply_menu "$_cid"
        done
        touch /etc/eye-bot.menu_sent 2>/dev/null || true
    fi
}

fastreply_label() {
    case "$1" in
        01_fastreply) echo "Здравствуйте! Кто вы и по какому вопросу?" ;;
        02_fastreply) echo "Внимание! Ведётся видеозапись." ;;
        03_fastreply) echo "Подождите минуту, сейчас открою." ;;
        04_fastreply) echo "Оставьте доставку у двери." ;;
        05_custom)    echo "Своя записанная фраза" ;;
        ptt_live)     echo "Повтор голосового сообщения" ;;
        *)            echo "$1" ;;
    esac
}

notify_group_action() {
    _who=$(printf "%s" "$1" | tr -d '<>&')
    _what="$2"
    _dst="${REPLY_CHAT_ID:-$(tg_primary_chat)}"
    case "$_dst" in
        -*)
            [ -z "$_who" ] && _who="Участник"
            tg_curl -X POST "${API_BASE}/sendMessage" \
                --data-urlencode "chat_id=${_dst}" \
                --data-urlencode "parse_mode=HTML" \
                --data-urlencode "disable_notification=true" \
                --data-urlencode "text=🔊 <b>${_who}</b> ответил(а) за дверью: <i>«${_what}»</i>" >/dev/null 2>&1 &
            ;;
    esac
}

render_screen() {
    _scr="$1"
    _force_offline="${2:-0}"
    if [ "$_force_offline" = "1" ]; then
        EYE_ONLINE=0
        load_offline_status_json
    else
        fetch_live_status >/dev/null 2>&1 || true
    fi

    _bat=$(jf bat "?")
    _bat_v=$(jf bat_v "")
    _bat_lbl="${_bat}%"
    [ -n "$_bat_v" ] && _bat_lbl="${_bat}% (${_bat_v} В)"
    _rssi=$(jf rssi "?")
    _sd=$(jf sd "MicroSD")
    _pir=$(jf pir "1")
    _stay=$(jf stay "10")
    _intv=$(jf interval "60")
    _eco=$(jf eco "0")
    _bscr=$(jf bscreen "0")
    _slpt=$(jf sleep_time "15")
    _night=$(jf night "0")
    _wdr=$(jf wdr "0")
    _ldc=$(jf ldc "1")
    _dbv=$(jf db_vol "2")
    _rot=$(jf cam_rotate "0")
    _keep=$(jf keep_awake "35")
    _spkv=$(jf speaker_vol "2")
    _arep=$(jf auto_reply "off")
    _aob=$(jf auto_only_bell "1")
    _dnd=$(jf dnd "0")
    _dnd_hrs=$(jf dnd_hours "23:00-8:00")
    _has_cv=$(jf custom_voice "false")
    _mqtt_en=$(jf mqtt_enable "0")
    _pwake=$(jf ping_wake "0")
    _lbat=$(jf low_bat "20")
    _wrem=$(jf wake_rem "0")
    _tz=$(jf tz "MSK-3")

    _rssi_s=""
    [ "$_rssi" != "?" ] && _rssi_s=" · ${_rssi} dBm"

    if [ "$EYE_ONLINE" = "1" ]; then
        _state_badge="🟢 На связи (<code>${EYE_IP}</code>${_rssi_s})"
    else
        _state_badge="💤 В глубоком сне &lt;1 мА · WoWLAN готов (<code>${EYE_IP}</code>)"
    fi

    case "$_scr" in
        voice)
            _at=$(auto_reply_title "$_arep")
            _astyle=""
            [ "$_arep" != "off" ] && _astyle=',"style":"success"'
            _amode_txt=$( [ "$_aob" = "1" ] && echo "🔔 Режим: Только на звонок" || echo "🚶 Режим: Звонок + движение" )
            _cv_row=""
            if [ "$_has_cv" = "true" ]; then
                _cv_row='[{"text":"🗣 Озвучить «Свою фразу»","callback_data":"say:05_custom","style":"success"}],'
            fi
            SCREEN_TEXT=$(printf "<b>🔊 ГОЛОСОВОЙ ОТВЕТ ЗА ДВЕРЬ</b>\n%s\nАвтоответ · <b>%s</b> (%s)\n\n💡 <b>Живой голос:</b> просто зажмите 🎙 микрофон в этом чате и отправьте голосовое сообщение — роутер сам разбудит глазок (если он спит) и сразу озвучит ваш голос посетителю!" "$_state_badge" "$_at" "$( [ "$_aob" = "1" ] && echo "только звонок" || echo "все события" )")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"🏃 Сейчас открою\",\"callback_data\":\"say:03_fastreply\",\"style\":\"success\"},{\"text\":\"🛍 Доставку у двери\",\"callback_data\":\"say:04_fastreply\",\"style\":\"primary\"}],${_cv_row}[{\"text\":\"❓ Здравствуйте! Кто вы?\",\"callback_data\":\"say:01_fastreply\"}],[{\"text\":\"📹 Внимание! Ведётся видеозапись\",\"callback_data\":\"say:02_fastreply\",\"style\":\"danger\"}],[{\"text\":\"🤖 Автоответ: ${_at}\",\"callback_data\":\"set:auto\"${_astyle}}],[{\"text\":\"${_amode_txt}\",\"callback_data\":\"set:auto_mode\"}],[{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            ;;

        clips)
            if ! wake_eye; then
                SCREEN_TEXT="<b>🎞 ВИДЕОАРХИВ MICROSD</b>

⚠️ Глазок сейчас не ответил на WoWLAN пробуждение."
                SCREEN_KB='{"inline_keyboard":[[{"text":"🔄 Повторить","callback_data":"menu:clips","style":"primary"},{"text":"⬅️ Назад в пульт","callback_data":"menu:main"}]]}'
                return
            fi
            _list_json=$(eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=list&limit=6")
            printf "%s" "$_list_json" > "$CLIPS_CACHE"
            _idx=0
            _lines=""
            _btns=""
            while [ "$_idx" -lt 6 ]; do
                _rel=$(printf "%s" "$_list_json" | jsonfilter -e "@[${_idx}].rel" 2>/dev/null)
                [ -z "$_rel" ] && break
                _lbl=$(printf "%s" "$_list_json" | jsonfilter -e "@[${_idx}].label" 2>/dev/null)
                _kb=$(printf "%s" "$_list_json" | jsonfilter -e "@[${_idx}].size_kb" 2>/dev/null)
                _mb=$(awk "BEGIN{printf \"%.1f\", ${_kb:-0}/1024}" 2>/dev/null || echo "${_kb}КБ")
                _num=$((_idx + 1))
                _lines="${_lines}
${_num}. 🎬 <b>${_lbl}</b> · ${_mb} МБ"
                _b="{\"text\":\"🎬 ${_lbl} (${_mb}М)\",\"callback_data\":\"clip:${_idx}\"}"
                if [ $((_num % 2)) -eq 1 ]; then
                    [ -n "$_btns" ] && _btns="${_btns},"
                    _btns="${_btns}[${_b}"
                else
                    _btns="${_btns},${_b}]"
                fi
                _idx=$((_idx + 1))
            done
            [ $((_idx % 2)) -eq 1 ] && _btns="${_btns}]"

            if [ "$_idx" -eq 0 ]; then
                SCREEN_TEXT=$(printf "<b>🎞 ВИДЕОАРХИВ MICROSD</b>\nПамять · <b>%s</b>\n\nЗаписей на карте памяти пока нет." "$_sd")
                SCREEN_KB='{"inline_keyboard":[[{"text":"🔄 Обновить","callback_data":"menu:clips"},{"text":"⬅️ Назад в пульт","callback_data":"menu:main"}]]}'
            else
                SCREEN_TEXT=$(printf "<b>🎞 ВИДЕОАРХИВ MICROSD</b>\nПамять · <b>%s</b>\nНажмите кнопку, чтобы скачать вертикальное видео в чат:%s" "$_sd" "$_lines")
                SCREEN_KB="{\"inline_keyboard\":[${_btns},[{\"text\":\"🔄 Обновить список\",\"callback_data\":\"menu:clips\"},{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            fi
            ;;

        pir)
            if [ "$_pir" = "1" ]; then
                _pt="🟢 Датчик движения: ВКЛ"
                _ps=',"style":"success"'
            else
                _pt="⚪ Датчик движения: ВЫКЛ (только звонок)"
                _ps=""
            fi
            _es=""
            [ "$_eco" = "1" ] && _es=',"style":"success"'
            SCREEN_TEXT=$(printf "<b>🛡 ДАТЧИК ДВИЖЕНИЯ (PIR)</b>\n%s\n\n• Датчик PIR: <b>%s</b>\n• Задержка у двери: <b>%s сек</b>\n• Пауза между записями: <b>%s сек</b>" "$_state_badge" "$( [ "$_pir" = "1" ] && echo "Включён" || echo "Выключен" )" "$_stay" "$_intv")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"${_pt}\",\"callback_data\":\"set:pir\"${_ps}}],[{\"text\":\"⏱ Ждать у двери: ${_stay} сек\",\"callback_data\":\"set:stay\"},{\"text\":\"⏳ Пауза: ${_intv} сек\",\"callback_data\":\"set:interval\"}],[{\"text\":\"🍃 Эко-режим: $( [ "$_eco" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:eco\"${_es}}],[{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            ;;

        cam)
            _nt=$(night_title "$_night")
            _ws=""
            [ "$_wdr" = "1" ] && _ws=',"style":"success"'
            _ls=""
            [ "$_ldc" = "1" ] && _ls=',"style":"success"'
            SCREEN_TEXT=$(printf "<b>📷 КАМЕРА И НОЧНОЙ РЕЖИМ</b>\n%s\n\n• Ночная ИК-подсветка: <b>%s</b>\n• WDR (против засветки): <b>%s</b>\n• Выпрямление линзы (LDC): <b>%s</b>\n• Поворот камеры и видео: <b>%s°</b>" "$_state_badge" "$_nt" "$( [ "$_wdr" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )" "$( [ "$_ldc" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )" "$_rot")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"🌙 ИК-ночь: ${_nt}\",\"callback_data\":\"set:night\",\"style\":\"primary\"},{\"text\":\"☀️ WDR: $( [ "$_wdr" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:wdr\"${_ws}}],[{\"text\":\"🔭 Выпрямление линзы: $( [ "$_ldc" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:ldc\"${_ls}}],[{\"text\":\"🔄 Поворот камеры и видео: ${_rot}°\",\"callback_data\":\"set:rot\"}],[{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            ;;

        snd)
            _bs=""
            [ "$_bscr" = "1" ] && _bs=',"style":"success"'
            _ds=""
            [ "$_dnd" = "1" ] && _ds=',"style":"success"'
            SCREEN_TEXT=$(printf "<b>🔔 ЗВУК, ЭКРАН И «ТИХИЙ ЧАС»</b>\n%s\n\n• Ночной «Тихий час» (%s): <b>%s</b>\n• Экран при звонке: <b>%s</b>\n• Автосон экрана: <b>%s сек</b>\n• Громкость за дверью: <b>%s / 2</b> · Дома: <b>%s / 3</b>" "$_state_badge" "$_dnd_hrs" "$( [ "$_dnd" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )" "$( [ "$_bscr" = "1" ] && echo "Зажигать" || echo "Не зажигать (экономия)" )" "$_slpt" "$_spkv" "$_dbv")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"🌙 Тихий час (${_dnd_hrs}): $( [ "$_dnd" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:dnd\"${_ds}}],[{\"text\":\"📱 Экран при звонке: $( [ "$_bscr" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:bscreen\"${_bs}}],[{\"text\":\"💤 Сон экрана: ${_slpt} сек\",\"callback_data\":\"set:sleeptm\"},{\"text\":\"🔔 Звонок дома: ${_dbv}/3\",\"callback_data\":\"set:dbvol\"}],[{\"text\":\"📢 Динамик на двери: $( [ "$_spkv" = "2" ] && echo "Макс (2)" || echo "Норм (1)" )\",\"callback_data\":\"set:spkvol\"}],[{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            ;;

        pwr)
            _tz_lbl=$(tz_label_ru "$_tz")
            _pws=""
            [ "$_pwake" = "1" ] && _pws=',"style":"success"'
            _mqs=""
            [ "$_mqtt_en" = "1" ] && _mqs=',"style":"success"'
            _mqtt_lbl=$( [ "$_mqtt_en" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ (0 мА)" )
            _lbat_lbl=$( [ "$_lbat" = "0" ] && echo "Выкл" || echo "${_lbat}%" )
            SCREEN_TEXT=$(printf "<b>🔋 ПИТАНИЕ, СОН И СИСТЕМА</b>\n%s\nЗаряд АКБ · <b>%s</b> · Пояс · <b>%s</b>\n\n• Не спать после звонка: <b>%s сек</b> · До сна: <b>%s сек</b>\n• Ping: <b>%s</b> · Порог АКБ: <b>%s</b>\n• Интеграция MQTT (HA): <b>%s</b>" "$_state_badge" "$_bat_lbl" "$_tz_lbl" "$_keep" "$_wrem" "$( [ "$_pwake" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )" "$_lbat_lbl" "$_mqtt_lbl")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"🌅 Разбудить +90с\",\"callback_data\":\"act:awake90\",\"style\":\"success\"},{\"text\":\"💤 Усыпить за 1 сек\",\"callback_data\":\"act:sleep\"}],[{\"text\":\"⏱ Бодрствование после звонка: ${_keep} сек\",\"callback_data\":\"set:keep\"}],[{\"text\":\"🕒 Пояс: ${_tz_lbl}\",\"callback_data\":\"set:tz\"}],[{\"text\":\"📡 Ping: $( [ "$_pwake" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:pingwake\"${_pws}},{\"text\":\"🪫 Порог АКБ: ${_lbat_lbl}\",\"callback_data\":\"set:lowbat\"}],[{\"text\":\"🏠 MQTT (Home Assistant): ${_mqtt_lbl}\",\"callback_data\":\"set:mqtt\"${_mqs}}],[{\"text\":\"🔄 Перезагрузить глазок\",\"callback_data\":\"menu:reboot_ask\",\"style\":\"danger\"}],[{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            ;;

        reboot_ask)
            SCREEN_TEXT="<b>⚠️ ПЕРЕЗАГРУЗКА ГЛАЗКА</b>

Разбудить и перезагрузить умный глазок?"
            SCREEN_KB='{"inline_keyboard":[[{"text":"⚠️ Да, перезагрузить","callback_data":"act:reboot","style":"danger"}],[{"text":"⬅️ Отмена","callback_data":"menu:pwr"}]]}'
            ;;

        *)
            _pir_s=$( [ "$_pir" = "1" ] && echo "ВКЛ (${_stay}с · пауза ${_intv}с)" || echo "ВЫКЛ (только звонок)" )
            _nt=$(night_title "$_night")
            if [ "$EYE_ONLINE" = "1" ]; then
                _bottom_btn="{\"text\":\"💤 Усыпить глазок за 1 сек\",\"callback_data\":\"act:sleep\"}"
            else
                _bottom_btn="{\"text\":\"🌅 Разбудить глазок (WoWLAN)\",\"callback_data\":\"act:wake\",\"style\":\"success\"}"
            fi
            SCREEN_TEXT=$(printf "<b>ГЛАЗОК XIAOBAI M1</b>\nСтатус · %s\n\n🔋 Батарея: <b>%s</b> · 💾 SD: <b>%s</b>\n🛡 Движение: <b>%s</b>\n📷 Камера: <b>ИК %s · WDR %s · %s°</b>" "$_state_badge" "$_bat_lbl" "$_sd" "$_pir_s" "$_nt" "$( [ "$_wdr" = "1" ] && echo "ВКЛ" || echo "Выкл" )" "$_rot")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"📸 Живое фото\",\"callback_data\":\"act:snap\",\"style\":\"primary\"},{\"text\":\"🎬 Запись 10с\",\"callback_data\":\"act:record\",\"style\":\"primary\"}],[{\"text\":\"🔊 Ответить у двери\",\"callback_data\":\"menu:voice\",\"style\":\"primary\"},{\"text\":\"🎞 Видеоархив\",\"callback_data\":\"menu:clips\"}],[{\"text\":\"🛡 Движение (PIR)\",\"callback_data\":\"menu:pir\"},{\"text\":\"📷 Камера и ИК\",\"callback_data\":\"menu:cam\"}],[{\"text\":\"🔔 Звук и экран\",\"callback_data\":\"menu:snd\"},{\"text\":\"🔋 Питание и сон\",\"callback_data\":\"menu:pwr\"}],[{\"text\":\"🔄 Обновить\",\"callback_data\":\"act:refresh\"},{\"text\":\"📋 Веб-панель · ${EYE_URL}\",\"copy_text\":{\"text\":\"${EYE_URL}\"}}],[${_bottom_btn}]]}"
            ;;
    esac
}

send_screen_card() {
    render_screen "$1" "${3:-0}"
    _dst="${2:-${REPLY_CHAT_ID:-$(tg_primary_chat)}}"
    tg_curl -X POST "${API_BASE}/sendMessage" \
        --data-urlencode "chat_id=${_dst}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${SCREEN_TEXT}" \
        --data-urlencode "reply_markup=${SCREEN_KB}" >/dev/null 2>&1
}

edit_screen_card() {
    _mid="$1"
    _scr="$2"
    _dst="${3:-${REPLY_CHAT_ID:-$(tg_primary_chat)}}"
    render_screen "$_scr" "${4:-0}"
    tg_curl -X POST "${API_BASE}/editMessageText" \
        --data-urlencode "chat_id=${_dst}" \
        --data-urlencode "message_id=${_mid}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${SCREEN_TEXT}" \
        --data-urlencode "reply_markup=${SCREEN_KB}" >/dev/null 2>&1
}

take_and_send_photo() {
    _title="$1"
    _dst="${2:-${REPLY_CHAT_ID:-$(tg_primary_chat)}}"
    if ! wake_eye; then
        tg_curl -X POST "${API_BASE}/sendMessage" \
            --data-urlencode "chat_id=${_dst}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "text=⚠️ Глазок (<code>${EYE_IP}</code>) не ответил на WoWLAN пробуждение за ${WAKE_TIMEOUT_SEC} сек." >/dev/null 2>&1
        return 1
    fi
    _snap_json=$(eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=snap")
    fetch_live_status >/dev/null 2>&1 || true
    _bat=$(jf bat "?")
    _bat_v=$(jf bat_v "")
    _bat_lbl="${_bat}%"
    [ -n "$_bat_v" ] && _bat_lbl="${_bat}% (${_bat_v} В)"
    _sd=$(jf sd "?")
    _pkb=$(build_photo_kb)

    if printf "%s" "$_snap_json" | grep -q '"ok":true'; then
        rm -f /tmp/eye_openwrt_snap.jpg
        if eye_curl -f -o /tmp/eye_openwrt_snap.jpg "${EYE_URL}/live.jpg?t=$(date +%s)" && [ -s /tmp/eye_openwrt_snap.jpg ]; then
            _cap=$(printf "<b>%s</b>\n🔋 Заряд · <b>%s</b>   💾 SD · <b>%s</b>\n🌐 <code>%s</code>" "$_title" "$_bat_lbl" "$_sd" "$EYE_URL")
            tg_curl -X POST "${API_BASE}/sendPhoto" \
                --form-string "chat_id=${_dst}" \
                -F "photo=@/tmp/eye_openwrt_snap.jpg" \
                --form-string "parse_mode=HTML" \
                --form-string "caption=${_cap}" \
                --form-string "reply_markup=${_pkb}" >/dev/null 2>&1
            rm -f /tmp/eye_openwrt_snap.jpg
            return 0
        fi
        rm -f /tmp/eye_openwrt_snap.jpg
    fi
    send_screen_card "main" "$_dst"
    return 0
}

apply_remote_setting() {
    _act="$1"
    _mid="$2"
    _cbid="$3"
    _dst="${REPLY_CHAT_ID:-$(tg_primary_chat)}"
    answer_cb "$_cbid" "📡 Бужу глазок и сохраняю настройку..."
    if ! wake_eye; then
        tg_curl -X POST "${API_BASE}/sendMessage" \
            --data-urlencode "chat_id=${_dst}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "text=⚠️ Не удалось разбудить глазок для смены настройки." >/dev/null 2>&1
        return 1
    fi

    _scr="main"
    case "$_act" in
        set:pir)
            _k="pir"; _v=$( [ "$(jf pir 1)" = "1" ] && echo 0 || echo 1 ); _scr="pir" ;;
        set:stay)
            _k="stay"; _v=$(cycle_next "$(jf stay 10)" 0 5 10 15 20); _scr="pir" ;;
        set:interval)
            _k="interval"; _v=$(cycle_next "$(jf interval 60)" 15 30 60 180); _scr="pir" ;;
        set:eco)
            _k="eco"; _v=$( [ "$(jf eco 0)" = "1" ] && echo 0 || echo 1 ); _scr="pir" ;;
        set:auto)
            _k="auto_reply"
            if [ "$(jf custom_voice false)" = "true" ]; then
                _v=$(cycle_next "$(jf auto_reply off)" off 04_fastreply 03_fastreply 05_custom 01_fastreply 02_fastreply)
            else
                _v=$(cycle_next "$(jf auto_reply off)" off 04_fastreply 03_fastreply 01_fastreply 02_fastreply)
            fi
            _scr="voice" ;;
        set:auto_mode)
            _k="auto_only_bell"; _v=$( [ "$(jf auto_only_bell 1)" = "1" ] && echo 0 || echo 1 ); _scr="voice" ;;
        set:night)
            _k="night"; _v=$(cycle_next "$(jf night 0)" 0 1 2); _scr="cam" ;;
        set:wdr)
            _k="wdr"; _v=$( [ "$(jf wdr 0)" = "1" ] && echo 0 || echo 1 ); _scr="cam" ;;
        set:ldc)
            _k="ldc"; _v=$( [ "$(jf ldc 1)" = "1" ] && echo 0 || echo 1 ); _scr="cam" ;;
        set:rot)
            _k="rot"; _v=$(cycle_next "$(jf cam_rotate 0)" 0 90 270 180); _scr="cam" ;;
        set:dnd)
            _k="dnd"; _v=$( [ "$(jf dnd 0)" = "1" ] && echo 0 || echo 1 ); _scr="snd" ;;
        set:bscreen)
            _k="bscreen"; _v=$( [ "$(jf bscreen 0)" = "1" ] && echo 0 || echo 1 ); _scr="snd" ;;
        set:sleeptm)
            _k="sleep_time"; _v=$(cycle_next "$(jf sleep_time 15)" 15 30 60); _scr="snd" ;;
        set:dbvol)
            _k="db_vol"; _v=$(cycle_next "$(jf db_vol 2)" 0 1 2 3); _scr="snd" ;;
        set:spkvol)
            _k="speaker_vol"; _v=$( [ "$(jf speaker_vol 2)" = "2" ] && echo 1 || echo 2 ); _scr="snd" ;;
        set:keep)
            _k="keep_awake"; _v=$(cycle_next "$(jf keep_awake 35)" 20 35 60 90); _scr="pwr" ;;
        set:tz)
            _k="tz"; _v=$(cycle_next "$(jf tz MSK-3)" MSK-3 SAMT-4 YEKT-5 OMST-6 KRAT-7 IRKT-8 VLAT-10 EET-2); _scr="pwr" ;;
        set:pingwake)
            _k="ping_wake"; _v=$( [ "$(jf ping_wake 0)" = "1" ] && echo 0 || echo 1 ); _scr="pwr" ;;
        set:lowbat)
            _k="low_bat"; _v=$(cycle_next "$(jf low_bat 20)" 20 15 30 0); _scr="pwr" ;;
        set:mqtt)
            _k="mqtt_enable"; _v=$( [ "$(jf mqtt_enable 0)" = "1" ] && echo 0 || echo 1 ); _scr="pwr" ;;
        *)
            return 0 ;;
    esac

    _res=$(eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=set_hw&key=${_k}&val=${_v}")
    if printf "%s" "$_res" | grep -q '"ok":true'; then
        save_status_cache "$_res"
    fi
    edit_screen_card "$_mid" "$_scr"
}

handle_openwrt_voice() {
    _fid="$1"
    _who=$(printf "%s" "$2" | tr -d '<>&')
    _dst="${REPLY_CHAT_ID:-$(tg_primary_chat)}"
    [ -n "$_fid" ] || return 1
    # Kick off WoWLAN wakeup immediately in parallel while downloading .oga from Telegram!
    ensure_arp_neighbor
    send_udp_packet "$EYE_BROADCAST" >/dev/null 2>&1 &
    send_udp_packet "$EYE_IP" >/dev/null 2>&1 &

    _gf=$(tg_curl -G "${API_BASE}/getFile" -d "file_id=${_fid}")
    _fsize=$(printf "%s" "$_gf" | jsonfilter -e '@.result.file_size' 2>/dev/null)
    if [ -n "$_fsize" ] && [ "$_fsize" -gt 2097152 ]; then
        tg_curl -X POST "${API_BASE}/sendMessage" \
            --data-urlencode "chat_id=${_dst}" \
            --data-urlencode "text=⚠️ Голосовое сообщение слишком длинное (макс. 30 сек)." >/dev/null 2>&1
        return 1
    fi
    _fpath=$(printf "%s" "$_gf" | jsonfilter -e '@.result.file_path' 2>/dev/null)
    if [ -z "$_fpath" ]; then
        return 1
    fi
    rm -f /tmp/eye_openwrt_voice.oga
    if ! tg_curl -o /tmp/eye_openwrt_voice.oga "${FILE_BASE}/${_fpath}" || [ ! -s /tmp/eye_openwrt_voice.oga ]; then
        rm -f /tmp/eye_openwrt_voice.oga
        return 1
    fi
    if ! wake_eye; then
        rm -f /tmp/eye_openwrt_voice.oga
        tg_curl -X POST "${API_BASE}/sendMessage" \
            --data-urlencode "chat_id=${_dst}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "text=⚠️ Глазок (<code>${EYE_IP}</code>) не ответил на WoWLAN пробуждение." >/dev/null 2>&1
        return 1
    fi
    _vres=$(curl -s --connect-timeout 4 --max-time 15 \
        -X POST -H "Content-Type: application/octet-stream" \
        --data-binary @/tmp/eye_openwrt_voice.oga \
        "${EYE_URL}/cgi-bin/api.cgi?action=speak_ogg&save=0")
    rm -f /tmp/eye_openwrt_voice.oga
    if printf "%s" "$_vres" | grep -q '"ok":true'; then
        _vsec=$(printf "%s" "$_vres" | jsonfilter -e '@.sec' 2>/dev/null)
        [ -z "$_vsec" ] && _vsec="?"
        if [ -n "$_who" ]; then
            _vtxt=$(printf "🎙 <b>%s · Голосовое (~%s сек) озвучено за дверью!</b>\nЗапишите ещё одно или выберите действие:" "$_who" "$_vsec")
        else
            _vtxt=$(printf "🎙 <b>Голосовое сообщение (~%s сек) озвучено за дверью!</b>\nЗапишите ещё одно или выберите действие:" "$_vsec")
        fi
        tg_curl -X POST "${API_BASE}/sendMessage" \
            --data-urlencode "chat_id=${_dst}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "text=${_vtxt}" \
            --data-urlencode "reply_markup=${VOICE_SENT_KB}" >/dev/null 2>&1
        return 0
    fi
    tg_curl -X POST "${API_BASE}/sendMessage" \
        --data-urlencode "chat_id=${_dst}" \
        --data-urlencode "text=⚠️ Ошибка воспроизведения голосового сообщения на глазке." >/dev/null 2>&1
    return 1
}

OFFSET=0
OFFSET_FILE="/etc/eye-bot.offset"
[ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

echo "eye-bot: Запущен круглосуточный кнопочный пульт для глазка ${EYE_IP}:${WOWLAN_PORT}"
ensure_arp_neighbor
init_bot_menu

while :; do
    RESP=$(tg_curl --max-time 35 -G "${API_BASE}/getUpdates" \
        -d "offset=${OFFSET}" \
        -d "limit=1" \
        -d "timeout=25")

    if [ -z "$RESP" ]; then
        sleep 3
        continue
    fi

    UID=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].update_id' 2>/dev/null)
    if [ -z "$UID" ]; then
        sleep 1
        continue
    fi

    OFFSET=$((UID + 1))
    echo "$OFFSET" > "$OFFSET_FILE"

    MSG_CHAT=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].message.chat.id' 2>/dev/null)
    CB_CHAT=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].callback_query.message.chat.id' 2>/dev/null)
    ACT_CHAT="${MSG_CHAT:-$CB_CHAT}"
    MSG_TEXT=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].message.text' 2>/dev/null)

    # Safe helper to discover private family group ID (-100...) without external bots
    case "$MSG_TEXT" in
        /id|/id@*|/chatid|/chatid@*)
            if [ -n "$ACT_CHAT" ]; then
                tg_curl -X POST "${API_BASE}/sendMessage" \
                    --data-urlencode "chat_id=${ACT_CHAT}" \
                    --data-urlencode "parse_mode=HTML" \
                    --data-urlencode "text=🆔 ID этого чата: <code>${ACT_CHAT}</code>" >/dev/null 2>&1
            fi
            continue
            ;;
    esac

    if [ -z "$ACT_CHAT" ] || ! is_chat_allowed "$ACT_CHAT"; then
        continue
    fi
    REPLY_CHAT_ID="$ACT_CHAT"

    CB_ID=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].callback_query.id' 2>/dev/null)
    CB_DATA=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].callback_query.data' 2>/dev/null)
    CB_MID=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].callback_query.message.message_id' 2>/dev/null)
    CB_WHO=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].callback_query.from.first_name' 2>/dev/null)
    MSG_WHO=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].message.from.first_name' 2>/dev/null)
    MSG_DATE=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].message.date' 2>/dev/null)
    VOICE_FID=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].message.voice.file_id' 2>/dev/null)
    [ -z "$VOICE_FID" ] && VOICE_FID=$(printf "%s" "$RESP" | jsonfilter -e '@.result[0].message.audio.file_id' 2>/dev/null)

    if [ -z "$CB_ID" ] && [ -n "$MSG_DATE" ]; then
        _now_ts=$(date +%s 2>/dev/null || echo 0)
        case "$MSG_DATE" in ''|*[!0-9]*) MSG_DATE=0 ;; esac
        if [ "$_now_ts" -gt 1700000000 ] && [ "$MSG_DATE" -gt 1700000000 ]; then
            _msg_age=$((_now_ts - MSG_DATE))
            if [ "$_msg_age" -gt 120 ]; then
                logger -t eye-bot "skip_stale_msg age=${_msg_age}s uid=${UID}"
                continue
            fi
        fi
    fi

    if [ -n "$CB_ID" ] && [ -n "$CB_DATA" ]; then
        case "$CB_DATA" in
            menu:open)
                answer_cb "$CB_ID" "🎛 Открываю пульт глазка"
                ensure_reply_menu "$REPLY_CHAT_ID"
                send_screen_card "main" "$REPLY_CHAT_ID"
                ;;
            menu:open_clips)
                answer_cb "$CB_ID" "🎞 Загружаю видеоархив..."
                send_screen_card "clips" "$REPLY_CHAT_ID"
                ;;
            menu:clips)
                answer_cb "$CB_ID" "🎞 Бужу глазок и читаю список записей..."
                edit_screen_card "$CB_MID" "clips" "$REPLY_CHAT_ID"
                ;;
            menu:*)
                answer_cb "$CB_ID" ""
                edit_screen_card "$CB_MID" "${CB_DATA#menu:}" "$REPLY_CHAT_ID"
                ;;
            set:*)
                apply_remote_setting "$CB_DATA" "$CB_MID" "$CB_ID"
                ;;
            say:*)
                SND="${CB_DATA#say:}"
                answer_cb "$CB_ID" "🔊 Бужу глазок и озвучиваю за дверью..."
                if wake_eye; then
                    eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=say&snd=${SND}" >/dev/null 2>&1
                    notify_group_action "$CB_WHO" "$(fastreply_label "$SND")"
                else
                    send_screen_card "main" "$REPLY_CHAT_ID"
                fi
                ;;
            act:save_ptt)
                answer_cb "$CB_ID" "💾 Сохраняю голосовое на MicroSD глазка..."
                if wake_eye; then
                    _sres=$(eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=save_last_ptt")
                    if printf "%s" "$_sres" | grep -q '"ok":true'; then
                        fetch_live_status >/dev/null 2>&1 || true
                        tg_curl -X POST "${API_BASE}/sendMessage" \
                            --data-urlencode "chat_id=${REPLY_CHAT_ID}" \
                            --data-urlencode "parse_mode=HTML" \
                            --data-urlencode "text=💾 <b>Голосовое сообщение сохранено на MicroSD как «Своя фраза»!</b>" >/dev/null 2>&1
                    fi
                fi
                ;;
            act:snap|snap:now)
                answer_cb "$CB_ID" "📸 Бужу глазок и делаю снимок..."
                take_and_send_photo "📸 ЖИВОЙ СНИМОК С ГЛАЗКА" "$REPLY_CHAT_ID"
                ;;
            act:record|record:now)
                answer_cb "$CB_ID" "🎬 Бужу глазок и запускаю запись 10 сек..."
                if wake_eye; then
                    _rres=$(eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=record&sec=10")
                    if ! printf "%s" "$_rres" | grep -q '"ok":true'; then
                        tg_curl -X POST "${API_BASE}/sendMessage" \
                            --data-urlencode "chat_id=${REPLY_CHAT_ID}" \
                            --data-urlencode "text=⚠️ Не удалось запустить запись на глазке." >/dev/null 2>&1
                    fi
                else
                    tg_curl -X POST "${API_BASE}/sendMessage" \
                        --data-urlencode "chat_id=${REPLY_CHAT_ID}" \
                        --data-urlencode "parse_mode=HTML" \
                        --data-urlencode "text=⚠️ Глазок (<code>${EYE_IP}</code>) не ответил на WoWLAN пробуждение." >/dev/null 2>&1
                fi
                ;;
            act:wake)
                answer_cb "$CB_ID" "🌅 Отправляю WoWLAN пакет пробуждения..."
                if wake_eye force; then
                    eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=awake&sec=60" >/dev/null 2>&1
                    edit_screen_card "$CB_MID" "main" "$REPLY_CHAT_ID"
                else
                    edit_screen_card "$CB_MID" "main" "$REPLY_CHAT_ID"
                    tg_curl -X POST "${API_BASE}/sendMessage" \
                        --data-urlencode "chat_id=${REPLY_CHAT_ID}" \
                        --data-urlencode "parse_mode=HTML" \
                        --data-urlencode "text=⚠️ Глазок (<code>${EYE_IP}</code>) не ответил на WoWLAN пробуждение (вне Wi-Fi или выключен)." >/dev/null 2>&1
                fi
                ;;
            act:awake90)
                answer_cb "$CB_ID" "🌅 Бужу глазок на +90 сек..."
                if wake_eye; then
                    eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=awake&sec=90" >/dev/null 2>&1
                fi
                edit_screen_card "$CB_MID" "pwr" "$REPLY_CHAT_ID"
                ;;
            act:refresh)
                answer_cb "$CB_ID" "🔄 Проверяю связь..."
                edit_screen_card "$CB_MID" "main" "$REPLY_CHAT_ID"
                ;;
            act:sleep|sleep:now)
                answer_cb "$CB_ID" "💤 Отправляю команду мгновенного сна"
                eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=sleep" >/dev/null 2>&1
                edit_screen_card "$CB_MID" "main" "$REPLY_CHAT_ID" "1"
                ;;
            act:reboot)
                answer_cb "$CB_ID" "🔄 Перезагружаю глазок..."
                if wake_eye; then
                    eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=reboot" >/dev/null 2>&1
                fi
                edit_screen_card "$CB_MID" "main" "$REPLY_CHAT_ID" "1"
                ;;
            clip:*)
                CIDX="${CB_DATA#clip:}"
                case "$CIDX" in ''|*[!0-9]*) CIDX="" ;; esac
                answer_cb "$CB_ID" "📥 Скачиваю запись с MicroSD и отправляю..."
                if [ -n "$CIDX" ] && wake_eye && [ -f "$CLIPS_CACHE" ]; then
                    CREL=$(cat "$CLIPS_CACHE" | jsonfilter -e "@[${CIDX}].rel" 2>/dev/null)
                    CLBL=$(cat "$CLIPS_CACHE" | jsonfilter -e "@[${CIDX}].label" 2>/dev/null)
                    rm -f /tmp/eye_openwrt_clip.mp4
                    if [ -n "$CREL" ] && curl -fsS --connect-timeout 4 --max-time 45 -o /tmp/eye_openwrt_clip.mp4 "${EYE_URL}/sd/${CREL}" && [ -s /tmp/eye_openwrt_clip.mp4 ]; then
                        tg_curl --max-time 90 -X POST "${API_BASE}/sendVideo" \
                            --form-string "chat_id=${REPLY_CHAT_ID}" \
                            -F "video=@/tmp/eye_openwrt_clip.mp4" \
                            --form-string "supports_streaming=true" \
                            --form-string "parse_mode=HTML" \
                            --form-string "caption=<b>🎬 Видеозапись · ${CLBL}</b>" \
                            --form-string "reply_markup=${CLIP_KB}" >/dev/null 2>&1
                    fi
                    rm -f /tmp/eye_openwrt_clip.mp4
                fi
                ;;
        esac
    elif [ -n "$VOICE_FID" ]; then
        ensure_reply_menu "$REPLY_CHAT_ID"
        handle_openwrt_voice "$VOICE_FID" "$MSG_WHO"
    elif [ -n "$MSG_TEXT" ]; then
        case "$MSG_TEXT" in
            *фото*|*Фото*|/photo*|/snap*)
                ensure_reply_menu "$REPLY_CHAT_ID"
                take_and_send_photo "📸 ЖИВОЙ СНИМОК С ГЛАЗКА" "$REPLY_CHAT_ID"
                ;;
            *Ответить*|*ответить*)
                ensure_reply_menu "$REPLY_CHAT_ID"
                send_screen_card "voice" "$REPLY_CHAT_ID"
                ;;
            *сон*|*Сон*|/sleep*)
                eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=sleep" >/dev/null 2>&1
                send_screen_card "main" "$REPLY_CHAT_ID" "1"
                ;;
            /wake*)
                wake_eye force >/dev/null 2>&1 || true
                eye_curl "${EYE_URL}/cgi-bin/api.cgi?action=awake&sec=90" >/dev/null 2>&1
                send_screen_card "main" "$REPLY_CHAT_ID"
                ;;
            *Пульт*|*пульт*|*Меню*|*меню*|/menu*|/start*)
                rm -f "/tmp/eye_bot_menu_$(printf "%s" "$REPLY_CHAT_ID" | tr -cd '0-9-')"
                ensure_reply_menu "$REPLY_CHAT_ID"
                send_screen_card "main" "$REPLY_CHAT_ID"
                ;;
            *)
                # In private 1-on-1 DM open menu on any text; in family group (-100...) don't spam human chat!
                case "$REPLY_CHAT_ID" in
                    -*) ;;
                    *)
                        ensure_reply_menu "$REPLY_CHAT_ID"
                        send_screen_card "main" "$REPLY_CHAT_ID"
                        ;;
                esac
                ;;
        esac
    fi
done
