#!/bin/sh
# Modern Telegram Bot Control Panel & Instant Notifier (/app/eye/tg_notify.sh)
# Zero slash commands required: Bot API 9.4+/10.1+ styled inline buttons + persistent reply menu.

. /app/eye/lib.sh
load_eye_conf

API_BASE="${TG_API_URL:-https://api.telegram.org}/bot${TG_BOT_TOKEN}"
FILE_BASE="${TG_API_URL:-https://api.telegram.org}/file/bot${TG_BOT_TOKEN}"

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

# Persistent bottom ReplyKeyboardMarkup (no slash commands needed)
REPLY_KB='{"keyboard":[[{"text":"🎛 Пульт глазка","style":"primary"},{"text":"📸 Живое фото"}],[{"text":"🔊 Ответить у двери"},{"text":"💤 В сон"}]],"resize_keyboard":true,"is_persistent":true,"input_field_placeholder":"🎙 Запишите голосовое за дверь или нажмите кнопку…"}'

VOICE_SENT_KB='{"inline_keyboard":[[{"text":"🔁 Повторить за дверью","callback_data":"say:ptt_live","style":"primary"},{"text":"📸 Живое фото","callback_data":"act:snap","style":"primary"}],[{"text":"💾 Сохранить как «Свою фразу»","callback_data":"act:save_ptt","style":"success"}],[{"text":"🎛 Пульт глазка","callback_data":"menu:open"},{"text":"💤 В сон","callback_data":"act:sleep"}]]}'

build_photo_kb() {
    if has_custom_voice; then
        echo '{"inline_keyboard":[[{"text":"🏃 Сейчас открою","callback_data":"say:03_fastreply","style":"primary"},{"text":"🛍 Доставку у двери","callback_data":"say:04_fastreply","style":"primary"}],[{"text":"🗣 Своя фраза","callback_data":"say:05_custom","style":"success"},{"text":"❓ Кто вы?","callback_data":"say:01_fastreply"}],[{"text":"📹 Ведётся запись!","callback_data":"say:02_fastreply"},{"text":"📸 Ещё фото","callback_data":"act:snap"}],[{"text":"🎛 Пульт глазка","callback_data":"menu:open"},{"text":"💤 В сон","callback_data":"act:sleep"}]]}'
    else
        echo '{"inline_keyboard":[[{"text":"🏃 Сейчас открою","callback_data":"say:03_fastreply","style":"primary"},{"text":"🛍 Доставку у двери","callback_data":"say:04_fastreply","style":"primary"}],[{"text":"❓ Кто вы?","callback_data":"say:01_fastreply"},{"text":"📹 Ведётся запись!","callback_data":"say:02_fastreply"}],[{"text":"📸 Ещё фото","callback_data":"act:snap"},{"text":"🎛 Пульт глазка","callback_data":"menu:open"}]]}'
    fi
}

CLIP_KB='{"inline_keyboard":[[{"text":"📸 Живое фото","callback_data":"act:snap","style":"primary"},{"text":"🎬 Запись 10с","callback_data":"act:record"},{"text":"🎛 Пульт глазка","callback_data":"menu:open"}]]}'

cycle_next() {
    _cur="$1"
    shift
    _first="$1"
    while [ $# -gt 0 ]; do
        if [ "$1" = "$_cur" ]; then
            shift
            if [ $# -gt 0 ]; then
                echo "$1"
            else
                echo "$_first"
            fi
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

build_caption() {
    _title="$1"
    _ts=$(date '+%H:%M:%S · %d.%m.%Y')
    _bat_lbl=$(get_battery_label)
    _ip=$(get_wlan_ip)
    _rssi=$(get_wifi_rssi)
    _rs=""
    [ "$_rssi" != "?" ] && _rs=" (${_rssi} dBm)"
    if [ -n "$_ip" ]; then
        printf "<b>%s</b>\n🕒 %s\n🔋 Заряд · <b>%s</b>   📶 <code>%s</code>%s" "$_title" "$_ts" "$_bat_lbl" "$_ip" "$_rs"
    else
        printf "<b>%s</b>\n🕒 %s\n🔋 Заряд · <b>%s</b>" "$_title" "$_ts" "$_bat_lbl"
    fi
}

# Build HTML text & InlineKeyboard JSON for any screen ("main", "voice", "clips", "pir", "cam", "snd", "pwr", "reboot_ask")
render_screen() {
    _scr="$1"
    load_eye_conf
    _bat=$(get_battery_pct)
    _bat_lbl=$(get_battery_label)
    _ip=$(get_wlan_ip)
    _rssi=$(get_wifi_rssi)
    _wport="${WEB_PORT:-8080}"
    _sd=$(get_sd_usage_str)
    _pir=$(get_nv "s_alarmSwitch" "1")
    _stay=$(get_nv "s_stayTime" "10")
    _intv=$(get_nv "s_videoInterval" "60")
    _eco=$(get_nv "s_powerSaveMode" "0")
    _bscr=$(get_nv "s_brightScreen" "0")
    _slpt=$(get_nv "sleep_time" "15")
    _night=$(get_nv "s_night" "0")
    _wdr=$(get_nv "s_wdr" "0")
    _ldc=$(get_nv "s_distortionCorrection" "1")
    _dbv=$(get_nv "doorbell_voice" "2")
    _arep="${AUTO_REPLY_SND:-off}"
    [ -z "$_arep" ] && _arep="off"
    _aob="${AUTO_REPLY_ONLY_BELL:-1}"
    _dnd="${DND_ENABLE:-0}"
    _pwake="${PING_WAKE:-0}"
    _lbat="${LOW_BAT_ALERT:-20}"
    _mqtt_en="${MQTT_ENABLE:-0}"
    _tz="${TZ:-MSK-3}"

    case "$_scr" in
        voice)
            _at=$(auto_reply_title "$_arep")
            _astyle=""
            [ "$_arep" != "off" ] && _astyle=',"style":"success"'
            _amode_txt=$( [ "$_aob" = "1" ] && echo "🔔 Режим: Только на звонок" || echo "🚶 Режим: Звонок + движение" )
            _cv_row=""
            if has_custom_voice; then
                _cv_row='[{"text":"🗣 Озвучить «Свою фразу»","callback_data":"say:05_custom","style":"success"}],'
            fi
            SCREEN_TEXT=$(printf "<b>🔊 ГОЛОСОВОЙ ОТВЕТ ЗА ДВЕРЬ</b>\nДинамик · Мужской голос (громкость %s/2)\nАвтоответ · <b>%s</b> (%s)\n\n💡 <b>Живой голос:</b> просто зажмите 🎙 микрофон в этом чате и отправьте голосовое сообщение — глазок сразу озвучит его посетителю!\nЛибо нажмите готовую фразу ниже:" "${SPEAKER_VOL:-2}" "$_at" "$( [ "$_aob" = "1" ] && echo "только звонок" || echo "все события" )")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"🏃 Сейчас открою\",\"callback_data\":\"say:03_fastreply\",\"style\":\"success\"},{\"text\":\"🛍 Доставку у двери\",\"callback_data\":\"say:04_fastreply\",\"style\":\"primary\"}],${_cv_row}[{\"text\":\"❓ Здравствуйте! Кто вы?\",\"callback_data\":\"say:01_fastreply\"}],[{\"text\":\"📹 Внимание! Ведётся видеозапись\",\"callback_data\":\"say:02_fastreply\",\"style\":\"danger\"}],[{\"text\":\"🤖 Автоответ: ${_at}\",\"callback_data\":\"set:auto\"${_astyle}}],[{\"text\":\"${_amode_txt}\",\"callback_data\":\"set:auto_mode\"}],[{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            ;;

        clips)
            rm -f /tmp/tg_clips.list
            touch /tmp/tg_clips.list
            _idx=0
            _lines=""
            _btns=""
            if [ -d /app/sd/MIJIA_RECORD_VIDEO ]; then
                for _mp4 in $(find /app/sd/MIJIA_RECORD_VIDEO -name "*.mp4" 2>/dev/null | sort -r | head -n 6); do
                    _idx=$((_idx + 1))
                    echo "$_mp4" >> /tmp/tg_clips.list
                    _rel="${_mp4#/app/sd/MIJIA_RECORD_VIDEO/}"
                    _lbl=$(format_clip_label "$_rel")
                    _kb=$(du -k "$_mp4" 2>/dev/null | awk '{print $1}')
                    _mb=$(awk "BEGIN{printf \"%.1f\", ${_kb:-0}/1024}" 2>/dev/null || echo "${_kb}КБ")
                    _lines="${_lines}
${_idx}. 🎬 <b>${_lbl}</b> · ${_mb} МБ"
                    _b="{\"text\":\"🎬 ${_lbl} (${_mb}М)\",\"callback_data\":\"clip:${_idx}\"}"
                    if [ $((_idx % 2)) -eq 1 ]; then
                        [ -n "$_btns" ] && _btns="${_btns},"
                        _btns="${_btns}[${_b}"
                    else
                        _btns="${_btns},${_b}]"
                    fi
                done
                [ $((_idx % 2)) -eq 1 ] && _btns="${_btns}]"
            fi
            if [ "$_idx" -eq 0 ]; then
                SCREEN_TEXT=$(printf "<b>🎞 ВИДЕОАРХИВ MICROSD</b>\nПамять · <b>%s</b>\n\nЗаписей на карте памяти пока нет." "$_sd")
                SCREEN_KB='{"inline_keyboard":[[{"text":"🔄 Обновить","callback_data":"menu:clips"},{"text":"⬅️ Назад в пульт","callback_data":"menu:main"}]]}'
            else
                SCREEN_TEXT=$(printf "<b>🎞 ВИДЕОАРХИВ MICROSD</b>\nПамять · <b>%s</b>\nНажмите на запись, чтобы получить видео в чат:%s" "$_sd" "$_lines")
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
            if [ "$_eco" = "1" ]; then
                _et="🍃 Эко-режим: ВКЛ"
                _es=',"style":"success"'
            else
                _et="🍃 Эко-режим: ВЫКЛ"
                _es=""
            fi
            SCREEN_TEXT=$(printf "<b>🛡 ДАТЧИК ДВИЖЕНИЯ (PIR)</b>\nЭкономия заряда и защита от ложных тревог\n\n• Датчик PIR: <b>%s</b>\n• Задержка у двери: <b>%s сек</b>\n• Пауза между записями: <b>%s сек</b>" "$( [ "$_pir" = "1" ] && echo "Включён" || echo "Выключен" )" "$_stay" "$_intv")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"${_pt}\",\"callback_data\":\"set:pir\"${_ps}}],[{\"text\":\"⏱ Ждать у двери: ${_stay} сек\",\"callback_data\":\"set:stay\"},{\"text\":\"⏳ Пауза: ${_intv} сек\",\"callback_data\":\"set:interval\"}],[{\"text\":\"${_et}\",\"callback_data\":\"set:eco\"${_es}}],[{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            ;;

        cam)
            _nt=$(night_title "$_night")
            _ws=""
            [ "$_wdr" = "1" ] && _ws=',"style":"success"'
            _ls=""
            [ "$_ldc" = "1" ] && _ls=',"style":"success"'
            _crot="${CAM_ROTATE:-0}"
            _res_lbl="1920×1080 (16:9)"
            case "$_crot" in 90|270) _res_lbl="1080×1920 (9:16)" ;; esac
            SCREEN_TEXT=$(printf "<b>📷 КАМЕРА И НОЧНОЙ РЕЖИМ</b>\nФормат · <b>H.265 %s</b> (экономия АКБ)\n\n• Ночная ИК-подсветка: <b>%s</b>\n• WDR (против засветки): <b>%s</b>\n• Выпрямление краёв (LDC): <b>%s</b>\n• Поворот камеры и видео: <b>%s°</b>" "$_res_lbl" "$_nt" "$( [ "$_wdr" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )" "$( [ "$_ldc" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )" "$_crot")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"🌙 ИК-ночь: ${_nt}\",\"callback_data\":\"set:night\",\"style\":\"primary\"},{\"text\":\"☀️ WDR: $( [ "$_wdr" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:wdr\"${_ws}}],[{\"text\":\"🔭 Выпрямление линзы: $( [ "$_ldc" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:ldc\"${_ls}}],[{\"text\":\"🔄 Поворот камеры и видео: ${_crot}°\",\"callback_data\":\"set:rot\"}],[{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            ;;

        snd)
            _bs=""
            [ "$_bscr" = "1" ] && _bs=',"style":"success"'
            _ds=""
            [ "$_dnd" = "1" ] && _ds=',"style":"success"'
            _dnd_lbl=$( [ "$_dnd" = "1" ] && echo "ВКЛ (${DND_START:-23}:00–${DND_END:-8}:00)" || echo "ВЫКЛ" )
            SCREEN_TEXT=$(printf "<b>🔔 ЗВУК, ЭКРАН И «ТИХИЙ ЧАС»</b>\nНастройки звонка внутри квартиры и на двери\n\n• Ночной «Тихий час»: <b>%s</b>\n• Экран при звонке: <b>%s</b>\n• Автосон экрана: <b>%s сек</b>\n• Громкость за дверью: <b>%s / 2</b> · Дома: <b>%s / 3</b>" "$_dnd_lbl" "$( [ "$_bscr" = "1" ] && echo "Зажигать" || echo "Не зажигать (экономия)" )" "$_slpt" "${SPEAKER_VOL:-2}" "$_dbv")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"🌙 Тихий час (${DND_START:-23}–${DND_END:-8}): $( [ "$_dnd" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:dnd\"${_ds}}],[{\"text\":\"📱 Экран при звонке: $( [ "$_bscr" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:bscreen\"${_bs}}],[{\"text\":\"💤 Сон экрана: ${_slpt} сек\",\"callback_data\":\"set:sleeptm\"},{\"text\":\"🔔 Звонок дома: ${_dbv}/3\",\"callback_data\":\"set:dbvol\"}],[{\"text\":\"📢 Динамик на двери: $( [ "${SPEAKER_VOL:-2}" = "2" ] && echo "Макс (2)" || echo "Норм (1)" )\",\"callback_data\":\"set:spkvol\"}],[{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            ;;

        pwr)
            _now=$(get_uptime_s)
            _unt=$(cat /tmp/eye_wake_until 2>/dev/null || echo 0)
            _rem=$((_unt - _now))
            [ "$_rem" -lt 0 ] && _rem=0
            _tz_lbl=$(tz_label_ru "$_tz")
            _pws=""
            [ "$_pwake" = "1" ] && _pws=',"style":"success"'
            _mqs=""
            [ "$_mqtt_en" = "1" ] && _mqs=',"style":"success"'
            _mqtt_lbl=$( [ "$_mqtt_en" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ (0 мА)" )
            _lbat_lbl=$( [ "$_lbat" = "0" ] && echo "Выкл" || echo "${_lbat}%" )
            SCREEN_TEXT=$(printf "<b>🔋 ПИТАНИЕ, СОН И СИСТЕМА</b>\nЗаряд батареи · <b>%s</b> (до сна: %s сек, сон &lt; 1 мА)\nЧасовой пояс · <b>%s</b> (%s)\n\n• После звонка не спать: <b>%s сек</b>\n• Пробуждение по Ping: <b>%s</b> · Порог АКБ: <b>%s</b>\n• Интеграция MQTT (HA): <b>%s</b>" "$_bat_lbl" "$_rem" "$_tz_lbl" "$(date '+%H:%M')" "${KEEP_AWAKE_SEC:-35}" "$( [ "$_pwake" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )" "$_lbat_lbl" "$_mqtt_lbl")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"☕ Не спать +90 сек\",\"callback_data\":\"act:awake90\",\"style\":\"primary\"},{\"text\":\"💤 Усыпить за 1 сек\",\"callback_data\":\"act:sleep\"}],[{\"text\":\"⏱ Бодрствование после звонка: ${KEEP_AWAKE_SEC:-35} сек\",\"callback_data\":\"set:keep\"}],[{\"text\":\"🕒 Пояс: ${_tz_lbl}\",\"callback_data\":\"set:tz\"}],[{\"text\":\"📡 Ping: $( [ "$_pwake" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ" )\",\"callback_data\":\"set:pingwake\"${_pws}},{\"text\":\"🪫 Порог АКБ: ${_lbat_lbl}\",\"callback_data\":\"set:lowbat\"}],[{\"text\":\"🏠 MQTT (Home Assistant): ${_mqtt_lbl}\",\"callback_data\":\"set:mqtt\"${_mqs}}],[{\"text\":\"🔄 Перезагрузить глазок\",\"callback_data\":\"menu:reboot_ask\",\"style\":\"danger\"}],[{\"text\":\"⬅️ Назад в пульт\",\"callback_data\":\"menu:main\"}]]}"
            ;;

        reboot_ask)
            SCREEN_TEXT="<b>⚠️ ПЕРЕЗАГРУЗКА ГЛАЗКА</b>

Вы уверены, что хотите перезагрузить умный глазок?"
            SCREEN_KB='{"inline_keyboard":[[{"text":"⚠️ Да, перезагрузить","callback_data":"act:reboot","style":"danger"}],[{"text":"⬅️ Отмена","callback_data":"menu:pwr"}]]}'
            ;;

        *)
            _pir_s=$( [ "$_pir" = "1" ] && echo "ВКЛ (${_stay}с / пауза ${_intv}с)" || echo "ВЫКЛ (только звонок)" )
            _nt=$(night_title "$_night")
            _url="http://${_ip:-192.168.1.50}:${_wport}"
            _rssi_s=""
            [ "$_rssi" != "?" ] && _rssi_s=" · ${_rssi} dBm"
            _dnd_s=""
            is_dnd_now && _dnd_s=" · 🌙 Тихий час"
            SCREEN_TEXT=$(printf "<b>ГЛАЗОК XIAOBAI M1</b>\nСтатус · 🟢 На связи (<code>%s</code>%s)%s\n\n🔋 Батарея: <b>%s</b> · 💾 SD: <b>%s</b>\n🛡 Движение: <b>%s</b>\n📷 Камера: <b>ИК %s · WDR %s · %s°</b>" "${_ip:-Wi-Fi}" "$_rssi_s" "$_dnd_s" "$_bat_lbl" "$_sd" "$_pir_s" "$_nt" "$( [ "$_wdr" = "1" ] && echo "ВКЛ" || echo "Выкл" )" "${CAM_ROTATE:-0}")
            SCREEN_KB="{\"inline_keyboard\":[[{\"text\":\"📸 Живое фото\",\"callback_data\":\"act:snap\",\"style\":\"primary\"},{\"text\":\"🎬 Запись 10с\",\"callback_data\":\"act:record\",\"style\":\"primary\"}],[{\"text\":\"🔊 Ответить у двери\",\"callback_data\":\"menu:voice\",\"style\":\"primary\"},{\"text\":\"🎞 Видеоархив\",\"callback_data\":\"menu:clips\"}],[{\"text\":\"🛡 Движение (PIR)\",\"callback_data\":\"menu:pir\"},{\"text\":\"📷 Камера и ИК\",\"callback_data\":\"menu:cam\"}],[{\"text\":\"🔔 Звук и экран\",\"callback_data\":\"menu:snd\"},{\"text\":\"🔋 Питание и сон\",\"callback_data\":\"menu:pwr\"}],[{\"text\":\"🔄 Обновить\",\"callback_data\":\"act:refresh\"},{\"text\":\"💤 В сон\",\"callback_data\":\"act:sleep\"}],[{\"text\":\"📋 Веб-панель · ${_url}\",\"copy_text\":{\"text\":\"${_url}\"}}]]}"
            ;;
    esac
}

send_tg_photo() {
    _photo="$1"
    _cap="$2"
    _silent="${3:-false}"
    _targets="${4:-$(tg_chat_list)}"
    [ -f "$_photo" ] || return 1
    _pkb=$(build_photo_kb)
    _cached_fid=""
    _last_res=""
    for _cid in $_targets; do
        if [ -z "$_cached_fid" ]; then
            _last_res=$(tg_curl -X POST "${API_BASE}/sendPhoto" \
                --form-string "chat_id=${_cid}" \
                -F "photo=@${_photo}" \
                --form-string "parse_mode=HTML" \
                --form-string "disable_notification=${_silent}" \
                --form-string "caption=${_cap}" \
                --form-string "reply_markup=${_pkb}")
            _cached_fid=$(printf "%s" "$_last_res" | tr -d '\r\n' | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p')
        else
            _last_res=$(tg_curl -X POST "${API_BASE}/sendPhoto" \
                --form-string "chat_id=${_cid}" \
                --form-string "photo=${_cached_fid}" \
                --form-string "parse_mode=HTML" \
                --form-string "disable_notification=${_silent}" \
                --form-string "caption=${_cap}" \
                --form-string "reply_markup=${_pkb}")
        fi
    done
    printf "%s" "$_last_res"
}

send_tg_video() {
    _vid="$1"
    _cap="$2"
    _silent="${3:-false}"
    _targets="${4:-$(tg_chat_list)}"
    [ -f "$_vid" ] || return 1
    _cached_fid=""
    _last_res=""
    for _cid in $_targets; do
        if [ -z "$_cached_fid" ]; then
            _last_res=$(tg_curl --max-time 35 -X POST "${API_BASE}/sendVideo" \
                --form-string "chat_id=${_cid}" \
                -F "video=@${_vid}" \
                --form-string "supports_streaming=true" \
                --form-string "parse_mode=HTML" \
                --form-string "disable_notification=${_silent}" \
                --form-string "caption=${_cap}" \
                --form-string "reply_markup=${CLIP_KB}")
            _cached_fid=$(printf "%s" "$_last_res" | tr -d '\r\n' | sed 's/"thumb":{[^}]*}//g; s/"thumbnail":{[^}]*}//g' | sed -n 's/.*"video":{[^}]*"file_id":"\([^"]*\)".*/\1/p')
        else
            _last_res=$(tg_curl -X POST "${API_BASE}/sendVideo" \
                --form-string "chat_id=${_cid}" \
                --form-string "video=${_cached_fid}" \
                --form-string "supports_streaming=true" \
                --form-string "parse_mode=HTML" \
                --form-string "disable_notification=${_silent}" \
                --form-string "caption=${_cap}" \
                --form-string "reply_markup=${CLIP_KB}")
        fi
    done
    printf "%s" "$_last_res"
}

send_screen_card() {
    render_screen "$1"
    _dst="${2:-${REPLY_CHAT_ID:-$(tg_primary_chat)}}"
    tg_curl -X POST "${API_BASE}/sendMessage" \
        --data-urlencode "chat_id=${_dst}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${SCREEN_TEXT}" \
        --data-urlencode "reply_markup=${SCREEN_KB}"
}

edit_screen_card() {
    _mid="$1"
    _scr="$2"
    _dst="${3:-${REPLY_CHAT_ID:-$(tg_primary_chat)}}"
    render_screen "$_scr"
    tg_curl -X POST "${API_BASE}/editMessageText" \
        --data-urlencode "chat_id=${_dst}" \
        --data-urlencode "message_id=${_mid}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${SCREEN_TEXT}" \
        --data-urlencode "reply_markup=${SCREEN_KB}" >/dev/null 2>&1
}

notify_group_action() {
    _who="$1"
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

ensure_reply_menu() {
    _dst="${1:-${REPLY_CHAT_ID:-$(tg_primary_chat)}}"
    _stamp="/app/sd/.tg_menu_init_$(printf "%s" "$_dst" | tr -cd '0-9-')"
    [ -f "$_stamp" ] && return 0
    tg_curl -X POST "${API_BASE}/setMyCommands" \
        --data-urlencode 'commands=[{"command":"menu","description":"🎛 Открыть пульт глазка"}]' >/dev/null 2>&1
    tg_curl -X POST "${API_BASE}/sendMessage" \
        --data-urlencode "chat_id=${_dst}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=🎛 <b>Кнопки быстрого управления закреплены внизу экрана</b>" \
        --data-urlencode "reply_markup=${REPLY_KB}" >/dev/null 2>&1
    touch "$_stamp" 2>/dev/null || true
}

start_poller_if_enabled() {
    [ "${TG_POLL_ON_DEVICE:-1}" = "1" ] || return 0
    if [ -f /var/run/tg_poll.pid ]; then
        _p=$(cat /var/run/tg_poll.pid 2>/dev/null)
        if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
            return 0
        fi
    fi
    /app/eye/tg_notify.sh --poll-loop >/dev/null 2>&1 &
}

answer_cb() {
    [ -n "$1" ] || return 0
    tg_curl -X POST "${API_BASE}/answerCallbackQuery" \
        --data-urlencode "callback_query_id=$1" \
        --data-urlencode "text=$2" >/dev/null 2>&1 &
}

handle_setting_cycle() {
    _act="$1"
    _mid="$2"
    _cbid="$3"
    load_eye_conf
    case "$_act" in
        set:pir)
            _v=$( [ "$(get_nv s_alarmSwitch 1)" = "1" ] && echo 0 || echo 1 )
            set_nv "s_alarmSwitch" "$_v"
            answer_cb "$_cbid" "$( [ "$_v" = "1" ] && echo "🟢 Датчик движения ВКЛ" || echo "⚪ Датчик движения ВЫКЛ" )"
            edit_screen_card "$_mid" "pir"
            ;;
        set:stay)
            _v=$(cycle_next "$(get_nv s_stayTime 10)" 0 5 10 15 20)
            set_nv "s_stayTime" "$_v"
            answer_cb "$_cbid" "⏱ Задержка у двери: ${_v} сек"
            edit_screen_card "$_mid" "pir"
            ;;
        set:interval)
            _v=$(cycle_next "$(get_nv s_videoInterval 60)" 15 30 60 180)
            set_nv "s_videoInterval" "$_v"
            answer_cb "$_cbid" "⏳ Пауза между записями: ${_v} сек"
            edit_screen_card "$_mid" "pir"
            ;;
        set:eco)
            _v=$( [ "$(get_nv s_powerSaveMode 0)" = "1" ] && echo 0 || echo 1 )
            set_nv "s_powerSaveMode" "$_v"
            answer_cb "$_cbid" "🍃 Эко-режим обновлён"
            edit_screen_card "$_mid" "pir"
            ;;
        set:auto)
            _cur="${AUTO_REPLY_SND:-off}"
            [ -z "$_cur" ] && _cur="off"
            if has_custom_voice; then
                _v=$(cycle_next "$_cur" off 04_fastreply 03_fastreply 05_custom 01_fastreply 02_fastreply)
            else
                _v=$(cycle_next "$_cur" off 04_fastreply 03_fastreply 01_fastreply 02_fastreply)
            fi
            if [ "$_v" = "off" ]; then set_conf_kv "AUTO_REPLY_SND" ""; else set_conf_kv "AUTO_REPLY_SND" "$_v"; fi
            answer_cb "$_cbid" "🤖 Автоответ: $(auto_reply_title "$_v")"
            edit_screen_card "$_mid" "voice"
            ;;
        set:auto_mode)
            _v=$( [ "${AUTO_REPLY_ONLY_BELL:-1}" = "1" ] && echo 0 || echo 1 )
            set_conf_kv "AUTO_REPLY_ONLY_BELL" "$_v"
            answer_cb "$_cbid" "$( [ "$_v" = "1" ] && echo "🔔 Автоответ только при звонке" || echo "🚶 Автоответ на звонок и движение" )"
            edit_screen_card "$_mid" "voice"
            ;;
        set:night)
            _v=$(cycle_next "$(get_nv s_night 0)" 0 1 2)
            set_nv "s_night" "$_v"
            answer_cb "$_cbid" "🌙 ИК-ночь: $(night_title "$_v")"
            edit_screen_card "$_mid" "cam"
            ;;
        set:wdr)
            _v=$( [ "$(get_nv s_wdr 0)" = "1" ] && echo 0 || echo 1 )
            set_nv "s_wdr" "$_v"
            answer_cb "$_cbid" "☀️ WDR обновлён"
            edit_screen_card "$_mid" "cam"
            ;;
        set:ldc)
            _v=$( [ "$(get_nv s_distortionCorrection 1)" = "1" ] && echo 0 || echo 1 )
            set_nv "s_distortionCorrection" "$_v"
            answer_cb "$_cbid" "🔭 Коррекция линзы обновлена"
            edit_screen_card "$_mid" "cam"
            ;;
        set:rot)
            _v=$(cycle_next "${CAM_ROTATE:-0}" 0 90 270 180)
            set_cam_and_vo_rotate "$_v"
            answer_cb "$_cbid" "🔄 Поворот камеры: ${_v}°"
            edit_screen_card "$_mid" "cam"
            ;;
        set:dnd)
            _v=$( [ "${DND_ENABLE:-0}" = "1" ] && echo 0 || echo 1 )
            set_conf_kv "DND_ENABLE" "$_v"
            apply_dnd_ram
            answer_cb "$_cbid" "$( [ "$_v" = "1" ] && echo "🌙 Тихий час ВКЛ (${DND_START:-23}:00–${DND_END:-8}:00)" || echo "☀️ Тихий час ВЫКЛ" )"
            edit_screen_card "$_mid" "snd"
            ;;
        set:bscreen)
            _v=$( [ "$(get_nv s_brightScreen 0)" = "1" ] && echo 0 || echo 1 )
            set_nv "s_brightScreen" "$_v"
            answer_cb "$_cbid" "📱 Экран при звонке обновлён"
            edit_screen_card "$_mid" "snd"
            ;;
        set:sleeptm)
            _v=$(cycle_next "$(get_nv sleep_time 15)" 15 30 60)
            set_nv "sleep_time" "$_v"
            answer_cb "$_cbid" "💤 Сон экрана: ${_v} сек"
            edit_screen_card "$_mid" "snd"
            ;;
        set:dbvol)
            _v=$(cycle_next "$(get_nv doorbell_voice 2)" 0 1 2 3)
            set_nv "doorbell_voice" "$_v"
            apply_dnd_ram
            answer_cb "$_cbid" "🔔 Громкость звонка дома: ${_v}/3"
            edit_screen_card "$_mid" "snd"
            ;;
        set:spkvol)
            _v=$( [ "${SPEAKER_VOL:-2}" = "2" ] && echo 1 || echo 2 )
            set_conf_kv "SPEAKER_VOL" "$_v"
            answer_cb "$_cbid" "📢 Динамик на двери: ${_v}/2"
            edit_screen_card "$_mid" "snd"
            ;;
        set:keep)
            _v=$(cycle_next "${KEEP_AWAKE_SEC:-35}" 20 35 60 90)
            set_conf_kv "KEEP_AWAKE_SEC" "$_v"
            extend_awake "$_v"
            answer_cb "$_cbid" "⏱ Ожидание после звонка: ${_v} сек"
            edit_screen_card "$_mid" "pwr"
            ;;
        set:tz)
            _v=$(cycle_next "${TZ:-MSK-3}" MSK-3 SAMT-4 YEKT-5 OMST-6 KRAT-7 IRKT-8 VLAT-10 EET-2)
            set_conf_kv "TZ" "$_v"
            sync_rtc_and_osd
            apply_dnd_ram
            answer_cb "$_cbid" "🕒 Часовой пояс: $(tz_label_ru "$_v")"
            edit_screen_card "$_mid" "pwr"
            ;;
        set:pingwake)
            _v=$( [ "${PING_WAKE:-0}" = "1" ] && echo 0 || echo 1 )
            set_conf_kv "PING_WAKE" "$_v"
            apply_wowlan
            answer_cb "$_cbid" "$( [ "$_v" = "1" ] && echo "📡 Пробуждение по Ping ВКЛ" || echo "📡 Пробуждение по Ping ВЫКЛ" )"
            edit_screen_card "$_mid" "pwr"
            ;;
        set:lowbat)
            _v=$(cycle_next "${LOW_BAT_ALERT:-20}" 20 15 30 0)
            set_conf_kv "LOW_BAT_ALERT" "$_v"
            set_nv "s_lowBattery" "$_v"
            answer_cb "$_cbid" "🪫 Порог уведомления: $( [ "$_v" = "0" ] && echo "Выкл" || echo "${_v}%" )"
            edit_screen_card "$_mid" "pwr"
            ;;
        set:mqtt)
            _v=$( [ "${MQTT_ENABLE:-0}" = "1" ] && echo 0 || echo 1 )
            set_conf_kv "MQTT_ENABLE" "$_v"
            rm -f /tmp/mqtt_disc_sent /tmp/mqtt_unreachable /app/sd/.mqtt_disc_v4_* 2>/dev/null || true
            if [ "$_v" = "1" ] && [ -z "$MQTT_HOST" ]; then
                answer_cb "$_cbid" "🏠 MQTT ВКЛ (укажите MQTT_HOST в eye.conf, когда настроите HA)"
            else
                answer_cb "$_cbid" "$( [ "$_v" = "1" ] && echo "🏠 MQTT (Home Assistant) ВКЛ" || echo "🏠 MQTT ВЫКЛ (0 мА)" )"
            fi
            edit_screen_card "$_mid" "pwr"
            ;;
    esac
}

handle_tg_voice_file() {
    _fid="$1"
    _who="$2"
    _dst="${REPLY_CHAT_ID:-$(tg_primary_chat)}"
    [ -n "$_fid" ] || return 1
    _gf=$(tg_curl -G "${API_BASE}/getFile" -d "file_id=${_fid}" 2>/dev/null | tr -d '\r\n')
    _fsize=$(printf "%s" "$_gf" | sed -n 's/.*"file_size":\([0-9][0-9]*\).*/\1/p')
    if [ -n "$_fsize" ] && [ "$_fsize" -gt 2097152 ]; then
        tg_curl -X POST "${API_BASE}/sendMessage" \
            --data-urlencode "chat_id=${_dst}" \
            --data-urlencode "text=⚠️ Голосовое сообщение слишком длинное (макс. 30 сек)." >/dev/null 2>&1
        return 1
    fi
    _fpath=$(printf "%s" "$_gf" | sed -n 's/.*"file_path":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g')
    if [ -z "$_fpath" ]; then
        return 1
    fi
    rm -f /tmp/tg_voice.oga
    if tg_curl -o /tmp/tg_voice.oga "${FILE_BASE}/${_fpath}" && [ -s /tmp/tg_voice.oga ]; then
        mkdir -p /tmp/sound
        if /app/bin/eye_tool ogg2alaw /tmp/tg_voice.oga /tmp/sound/ptt_live; then
            rm -f /tmp/tg_voice.oga
            chmod 755 /tmp/sound/ptt_live 2>/dev/null || true
            _asz=$(wc -c < /tmp/sound/ptt_live 2>/dev/null | tr -cd '0-9')
            _sec=$(( (${_asz:-8000} + 4000) / 8000 ))
            [ "$_sec" -lt 1 ] && _sec=1
            extend_awake $((_sec + 40))
            play_fastreply "ptt_live"
            if [ -n "$_who" ]; then
                _vtxt=$(printf "🎙 <b>%s · Голосовое (~%s сек) озвучено за дверью!</b>\nЗапишите ещё одно или выберите действие:" "$_who" "$_sec")
            else
                _vtxt=$(printf "🎙 <b>Голосовое сообщение (~%s сек) озвучено за дверью!</b>\nЗапишите ещё одно или выберите действие:" "$_sec")
            fi
            tg_curl -X POST "${API_BASE}/sendMessage" \
                --data-urlencode "chat_id=${_dst}" \
                --data-urlencode "parse_mode=HTML" \
                --data-urlencode "text=${_vtxt}" \
                --data-urlencode "reply_markup=${VOICE_SENT_KB}" >/dev/null 2>&1
            return 0
        fi
    fi
    rm -f /tmp/tg_voice.oga
    tg_curl -X POST "${API_BASE}/sendMessage" \
        --data-urlencode "chat_id=${_dst}" \
        --data-urlencode "text=⚠️ Не удалось распознать голосовое сообщение (отправьте обычное голосовое микрофоном Telegram)." >/dev/null 2>&1
    return 1
}

run_poll_loop() {
    echo $$ > /var/run/tg_poll.pid
    _offset_file="/tmp/tg_offset"
    [ -f /app/sd/.tg_offset ] && [ ! -f "$_offset_file" ] && cp /app/sd/.tg_offset "$_offset_file" 2>/dev/null || true
    _err_cnt=0

    while [ -f /tmp/eye_wake_until ]; do
        _until=$(cat /tmp/eye_wake_until 2>/dev/null || echo 0)
        _now=$(get_uptime_s)
        [ "$_now" -ge "$_until" ] && break

        _off=$(cat "$_offset_file" 2>/dev/null || echo 0)
        case "$_off" in ''|*[!0-9]*) _off=0 ;; esac

        _resp=$(tg_curl --max-time 8 -G "${API_BASE}/getUpdates" \
            -d "offset=${_off}" \
            -d "limit=1" \
            -d "timeout=4" 2>/dev/null | tr -d '\r\n')

        if printf "%s" "$_resp" | grep -q '"error_code":409'; then
            break
        fi
        if [ -z "$_resp" ] || ! printf "%s" "$_resp" | grep -q '"ok":true'; then
            _err_cnt=$((_err_cnt + 1))
            if [ "$_err_cnt" -ge 3 ]; then
                get_uptime_s > /tmp/tg_unreachable 2>/dev/null || true
                break
            fi
            sleep 2
            continue
        fi
        _err_cnt=0

        _uid=$(printf "%s" "$_resp" | sed -n 's/.*"update_id":\([0-9][0-9]*\).*/\1/p')
        if [ -n "$_uid" ]; then
            _next=$((_uid + 1))
            echo "$_next" > "$_offset_file"
            echo "$_next" > /app/sd/.tg_offset 2>/dev/null || true

            # Strip nested reply_to_message object (if user swiped-to-reply in a group) so sed never matches inner fields
            case "$_resp" in
                *'"reply_to_message":{'*)
                    _parse_resp=$(printf "%s" "$_resp" | awk '{
                        idx = index($0, "\"reply_to_message\":{")
                        if (!idx) { print $0; next }
                        pre = substr($0, 1, idx - 1)
                        rest = substr($0, idx + 20)
                        d = 1; in_s = 0; esc = 0; i = 1; n = length(rest)
                        while (i <= n && d > 0) {
                            c = substr(rest, i, 1)
                            if (esc) { esc = 0 }
                            else if (c == "\\") { esc = 1 }
                            else if (c == "\"") { in_s = !in_s }
                            else if (!in_s) {
                                if (c == "{") d++
                                else if (c == "}") d--
                            }
                            i++
                        }
                        if (substr(rest, i, 1) == ",") i++
                        print pre substr(rest, i)
                    }')
                    ;;
                *)
                    _parse_resp="$_resp"
                    ;;
            esac

            _chat=$(printf "%s" "$_parse_resp" | sed -n 's/.*"chat":{"id":\([-0-9][0-9]*\).*/\1/p')
            _cb_id=$(printf "%s" "$_parse_resp" | sed -n 's/.*"callback_query":{"id":"\([^"]*\)".*/\1/p')
            _msg_txt=""
            if [ -z "$_cb_id" ]; then
                _msg_txt=$(printf "%s" "$_parse_resp" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
            fi

            # Safe helper to discover private family group ID (-100...) without external bots
            case "$_msg_txt" in
                /id|/id@*|/chatid|/chatid@*)
                    if [ -n "$_chat" ]; then
                        tg_curl -X POST "${API_BASE}/sendMessage" \
                            --data-urlencode "chat_id=${_chat}" \
                            --data-urlencode "parse_mode=HTML" \
                            --data-urlencode "text=🆔 ID этого чата: <code>${_chat}</code>" >/dev/null 2>&1
                    fi
                    continue
                    ;;
            esac

            # Verify authorized TG_CHAT_ID (supports group -100... and comma/space-separated family IDs)
            if [ -z "$_chat" ] || ! is_chat_allowed "$_chat"; then
                continue
            fi
            REPLY_CHAT_ID="$_chat"

            if [ -n "$_cb_id" ]; then
                _who=$(printf "%s" "$_parse_resp" | sed -n 's/.*"callback_query":{"id":"[^"]*","from":{[^}]*"first_name":"\([^"]*\)".*/\1/p' | tr -d '<>&')
            else
                _who=$(printf "%s" "$_parse_resp" | sed -n 's/.*"from":{[^}]*"first_name":"\([^"]*\)".*/\1/p' | tr -d '<>&')
            fi
            _cb_data=$(printf "%s" "$_parse_resp" | sed -n 's/.*"data":"\([^"]*\)".*/\1/p')
            _msg_id=$(printf "%s" "$_parse_resp" | sed -n 's/.*"message":{"message_id":\([0-9][0-9]*\).*/\1/p')
            _voice_fid=$(printf "%s" "$_parse_resp" | sed -n 's/.*"voice":{[^}]*"file_id":"\([^"]*\)".*/\1/p')
            if [ -z "$_voice_fid" ]; then
                _voice_fid=$(printf "%s" "$_parse_resp" | sed 's/"thumb":{[^}]*}//g; s/"thumbnail":{[^}]*}//g' | sed -n 's/.*"audio":{[^}]*"file_id":"\([^"]*\)".*/\1/p')
            fi

            if [ -n "$_cb_id" ] && [ -n "$_cb_data" ]; then
                touch /tmp/eye_user_active
                extend_awake 45
                case "$_cb_data" in
                    menu:open)
                        answer_cb "$_cb_id" "🎛 Открываю пульт глазка"
                        ensure_reply_menu "$REPLY_CHAT_ID"
                        send_screen_card "main" "$REPLY_CHAT_ID" >/dev/null 2>&1
                        ;;
                    menu:*)
                        _target="${_cb_data#menu:}"
                        answer_cb "$_cb_id" ""
                        edit_screen_card "$_msg_id" "$_target" "$REPLY_CHAT_ID"
                        ;;
                    set:*)
                        handle_setting_cycle "$_cb_data" "$_msg_id" "$_cb_id"
                        ;;
                    say:01_fastreply)
                        play_fastreply "01_fastreply"
                        answer_cb "$_cb_id" "🔊 Озвучено: Здравствуйте! Кто вы и по какому вопросу?"
                        notify_group_action "$_who" "Здравствуйте! Кто вы и по какому вопросу?"
                        ;;
                    say:02_fastreply)
                        play_fastreply "02_fastreply"
                        answer_cb "$_cb_id" "🔊 Озвучено: Внимание! Ведётся видеозапись."
                        notify_group_action "$_who" "Внимание! Ведётся видеозапись."
                        ;;
                    say:03_fastreply)
                        play_fastreply "03_fastreply"
                        answer_cb "$_cb_id" "🔊 Озвучено: Подождите минуту, сейчас открою."
                        notify_group_action "$_who" "Подождите минуту, сейчас открою."
                        ;;
                    say:04_fastreply)
                        play_fastreply "04_fastreply"
                        answer_cb "$_cb_id" "🔊 Озвучено: Оставьте доставку у двери."
                        notify_group_action "$_who" "Оставьте доставку у двери."
                        ;;
                    say:05_custom)
                        if play_fastreply "05_custom"; then
                            answer_cb "$_cb_id" "🔊 Озвучена ваша записанная фраза!"
                            notify_group_action "$_who" "Своя записанная фраза"
                        else
                            answer_cb "$_cb_id" "⚠️ Запишите голосовое сообщение в чат и нажмите «Сохранить»"
                        fi
                        ;;
                    say:ptt_live)
                        if play_fastreply "ptt_live"; then
                            answer_cb "$_cb_id" "🔁 Голосовое сообщение повторено за дверью!"
                            notify_group_action "$_who" "Повтор голосового сообщения"
                        else
                            answer_cb "$_cb_id" "⚠️ Запись в ОЗУ уже очищена — отправьте новое голосовое"
                        fi
                        ;;
                    act:save_ptt)
                        if [ -s /tmp/sound/ptt_live ]; then
                            ensure_sd_mounted
                            mkdir -p /app/sd/voices 2>/dev/null || true
                            cp /tmp/sound/ptt_live /app/sd/voices/05_custom 2>/dev/null || cp /tmp/sound/ptt_live /tmp/sound/05_custom 2>/dev/null || true
                            sync
                            sync_custom_voices
                            answer_cb "$_cb_id" "💾 Сохранено на MicroSD как «Своя фраза»!"
                        else
                            answer_cb "$_cb_id" "⚠️ Сначала отправьте голосовое сообщение в чат"
                        fi
                        ;;
                    act:snap|snap:now)
                        answer_cb "$_cb_id" "📸 Делаю живой снимок..."
                        if /app/bin/eye_snap /tmp/tg_snap.jpg "${CAM_ROTATE:-90}" 3500; then
                            send_mqtt_snapshot /tmp/tg_snap.jpg "live"
                            send_tg_photo /tmp/tg_snap.jpg "$(build_caption '📸 Живой снимок с глазка')" "false" "$REPLY_CHAT_ID" >/dev/null 2>&1
                        fi
                        ;;
                    act:record|record:now)
                        answer_cb "$_cb_id" "🎬 Пишу видео 10 сек со звуком..."
                        (
                            _rres=$(/app/eye/ui_action.sh record 10 2>/dev/null)
                            _rrc=$?
                            if [ "$_rrc" -ne 0 ]; then
                                _rmsg="⚠️ Не удалось записать видео."
                                [ "$_rres" = "ERR:busy" ] && _rmsg="⏳ Запись или снимок уже выполняется."
                                tg_curl -X POST "${API_BASE}/sendMessage" \
                                    --data-urlencode "chat_id=${REPLY_CHAT_ID}" \
                                    --data-urlencode "text=${_rmsg}" >/dev/null 2>&1 || true
                            fi
                        ) >/dev/null 2>&1 &
                        ;;
                    act:refresh)
                        answer_cb "$_cb_id" "✅ Статус обновлён"
                        edit_screen_card "$_msg_id" "main" "$REPLY_CHAT_ID"
                        ;;
                    act:awake90)
                        extend_awake 90
                        answer_cb "$_cb_id" "☕ Время бодрствования продлено на 90 сек"
                        edit_screen_card "$_msg_id" "pwr" "$REPLY_CHAT_ID"
                        ;;
                    act:sleep|sleep:now)
                        answer_cb "$_cb_id" "💤 Выключаю питание SoC (глубокий сон < 1 мА)"
                        release_awake_now
                        break
                        ;;
                    act:reboot)
                        answer_cb "$_cb_id" "🔄 Перезагружаю глазок..."
                        (mark_clean_reboot; /app/bin/recovery 0 >/dev/null 2>&1; sync; sleep 1; reboot -f) >/dev/null 2>&1 &
                        break
                        ;;
                    clip:*)
                        _cidx="${_cb_data#clip:}"
                        case "$_cidx" in ''|*[!0-9]*) _cidx="" ;; esac
                        _cfile=""
                        [ -n "$_cidx" ] && [ "$_cidx" -ge 1 ] && _cfile=$(sed -n "${_cidx}p" /tmp/tg_clips.list 2>/dev/null)
                        if [ -n "$_cfile" ] && [ -f "$_cfile" ]; then
                            answer_cb "$_cb_id" "📤 Отправляю видеозапись в чат..."
                            _crel="${_cfile#/app/sd/MIJIA_RECORD_VIDEO/}"
                            send_tg_video "$_cfile" "$(build_caption "🎬 Запись · $(format_clip_label "$_crel")")" "false" "$REPLY_CHAT_ID" >/dev/null 2>&1
                        else
                            answer_cb "$_cb_id" "⚠️ Файл не найден, обновите список"
                        fi
                        ;;
                esac
            elif [ -n "$_voice_fid" ]; then
                touch /tmp/eye_user_active
                extend_awake 55
                ensure_reply_menu "$REPLY_CHAT_ID"
                handle_tg_voice_file "$_voice_fid" "$_who"
            elif [ -n "$_msg_txt" ]; then
                case "$_msg_txt" in
                    *фото*|*Фото*|*0444\\u043e\\u0442\\u043e*|/photo*|/snap*)
                        touch /tmp/eye_user_active
                        extend_awake 45
                        ensure_reply_menu "$REPLY_CHAT_ID"
                        if /app/bin/eye_snap /tmp/tg_snap.jpg "${CAM_ROTATE:-90}" 3500; then
                            send_mqtt_snapshot /tmp/tg_snap.jpg "live"
                            send_tg_photo /tmp/tg_snap.jpg "$(build_caption '📸 Живой снимок с глазка')" "false" "$REPLY_CHAT_ID" >/dev/null 2>&1
                        fi
                        ;;
                    *Ответить*|*ответить*|*0442\\u0432\\u0435\\u0442*)
                        touch /tmp/eye_user_active
                        extend_awake 45
                        ensure_reply_menu "$REPLY_CHAT_ID"
                        send_screen_card "voice" "$REPLY_CHAT_ID" >/dev/null 2>&1
                        ;;
                    *сон*|*Сон*|*0441\\u043e\\u043d*|/sleep*)
                        touch /tmp/eye_user_active
                        tg_curl -X POST "${API_BASE}/sendMessage" \
                            --data-urlencode "chat_id=${REPLY_CHAT_ID}" \
                            --data-urlencode "text=💤 Глазок мгновенно переходит в глубокий сон (< 1 мА)." \
                            --data-urlencode "reply_markup=${REPLY_KB}" >/dev/null 2>&1
                        release_awake_now
                        break
                        ;;
                    *Пульт*|*пульт*|*Меню*|*меню*|*0443\\u043b\\u044c\\u0442*|/menu*|/start*)
                        touch /tmp/eye_user_active
                        extend_awake 45
                        ensure_reply_menu "$REPLY_CHAT_ID"
                        send_screen_card "main" "$REPLY_CHAT_ID" >/dev/null 2>&1
                        ;;
                    *)
                        # In private 1-on-1 DM open menu on any text; in family group (-100...) don't spam human chat!
                        case "$REPLY_CHAT_ID" in
                            -*) ;;
                            *)
                                touch /tmp/eye_user_active
                                extend_awake 45
                                ensure_reply_menu "$REPLY_CHAT_ID"
                                send_screen_card "main" "$REPLY_CHAT_ID" >/dev/null 2>&1
                                ;;
                        esac
                        ;;
                esac
            fi
        fi
    done

    rm -f /var/run/tg_poll.pid
}

MODE="$1"

if [ "$MODE" = "--poll-loop" ]; then
    [ -n "$TG_BOT_TOKEN" ] && run_poll_loop
    exit 0
fi

# Wait briefly for wlan0 IP if invoked early during wakeup
_w=0
while [ $_w -lt 16 ]; do
    [ -n "$(get_wlan_ip)" ] && break
    usleep 500000 2>/dev/null || sleep 1
    _w=$((_w + 1))
done

case "$MODE" in
    --lowbat)
        BAT_ARG="${2:-$(get_battery_pct)}"
        BV_ARG=$(get_battery_v)
        [ -n "$BV_ARG" ] && BAT_DISP="${BAT_ARG}% · ${BV_ARG} В" || BAT_DISP="${BAT_ARG}%"
        send_ntfy_push "" "lowbat"
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            LOW_KB='{"inline_keyboard":[[{"text":"🎛 Пульт глазка","callback_data":"menu:open","style":"primary"},{"text":"💤 В сон","callback_data":"act:sleep"}]]}'
            LOW_TXT=$(printf "🪫 <b>НИЗКИЙ ЗАРЯД БАТАРЕИ (%s)</b>\nПоставьте умный глазок на зарядку (MicroUSB 5V 2A)." "$BAT_DISP")
            for _cid in $(tg_chat_list); do
                tg_curl -X POST "${API_BASE}/sendMessage" \
                    --data-urlencode "chat_id=${_cid}" \
                    --data-urlencode "parse_mode=HTML" \
                    --data-urlencode "text=${LOW_TXT}" \
                    --data-urlencode "reply_markup=${LOW_KB}" >/dev/null 2>&1
            done
        fi
        exit 0
        ;;
    --live)
        if [ "${TG_POLL_ON_DEVICE:-1}" != "1" ]; then
            [ -f /tmp/force_sleep_now ] || extend_awake 15
            exit 0
        fi
        ;;
esac

[ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || exit 0

case "$MODE" in
    --alarm)
        RAW_JPG="${2:-/dev/alarm0.jpeg}"
        _ev=$(detect_event_type)
        if [ "$_ev" = "bell" ]; then
            extend_awake "${KEEP_AWAKE_SEC:-35}"
        else
            extend_awake 25
        fi
        _silent="false"
        is_dnd_now && [ "$_ev" != "bell" ] && _silent="true"
        _title=$(event_title_ru "$_ev")
        if [ -f "$RAW_JPG" ]; then
            if [ "$RAW_JPG" = "/tmp/tg_alarm.jpg" ]; then
                send_ntfy_push /tmp/tg_alarm.jpg "$_ev"
                send_tg_photo /tmp/tg_alarm.jpg "$(build_caption "$_title")" "$_silent" >/dev/null 2>&1
            elif /app/bin/eye_tool jpgrot "$RAW_JPG" /tmp/tg_alarm.jpg "${CAM_ROTATE:-90}" 85; then
                send_ntfy_push /tmp/tg_alarm.jpg "$_ev"
                send_tg_photo /tmp/tg_alarm.jpg "$(build_caption "$_title")" "$_silent" >/dev/null 2>&1
            fi
        fi
        if [ -f /tmp/tg_unreachable ]; then
            trim_awake_if_idle 2
        else
            start_poller_if_enabled
        fi
        ;;

    --clip)
        MP4_FILE="$2"
        JPG_FILE="${3:-${MP4_FILE%.mp4}.jpeg}"
        _ev="${EYE_EVENT_OVERRIDE:-$(detect_event_type)}"
        if [ "$_ev" = "bell" ] || [ "$_ev" = "manual" ]; then
            extend_awake "${KEEP_AWAKE_SEC:-35}"
        else
            extend_awake 20
        fi
        _silent="false"
        is_dnd_now && [ "$_ev" != "bell" ] && [ "$_ev" != "manual" ] && _silent="true"
        _title=$(event_title_ru "$_ev")
        case "$_ev" in
            bell)   _vtitle="🎥 ВИДЕО · ЗВОНОК В ДВЕРЬ" ;;
            stay)   _vtitle="🎥 ВИДЕО · КТО-ТО У ДВЕРИ" ;;
            motion) _vtitle="🎥 ВИДЕО · ДВИЖЕНИЕ У ДВЕРИ" ;;
            manual)
                if [ -n "${EYE_REC_DUR:-}" ]; then
                    _vtitle="🎬 РУЧНАЯ ВИДЕОЗАПИСЬ (${EYE_REC_DUR} СЕК)"
                else
                    _vtitle="🎬 РУЧНАЯ ВИДЕОЗАПИСЬ"
                fi
                ;;
            *)      _vtitle="🎥 ВИДЕОЗАПИСЬ У ДВЕРИ" ;;
        esac

        _send_thumb=1
        [ "$_ev" = "manual" ] && _send_thumb=0
        if [ "$_send_thumb" -eq 1 ] && [ -f /tmp/eye_boot_alarm_sent ]; then
            _ats=$(cat /tmp/eye_boot_alarm_sent 2>/dev/null || echo 0)
            case "$_ats" in ''|*[!0-9]*) _ats=0 ;; esac
            _now=$(get_uptime_s)
            if [ "$_now" -ge "$_ats" ] && [ $((_now - _ats)) -lt 25 ]; then
                _send_thumb=0
                rm -f /tmp/eye_boot_alarm_sent
            fi
        fi

        if [ "$_send_thumb" -eq 1 ] && [ -f "$JPG_FILE" ]; then
            send_tg_photo "$JPG_FILE" "$(build_caption "$_title")" "$_silent" >/dev/null 2>&1
        fi

        if [ "${TG_SEND_VIDEO:-1}" = "1" ] && [ -f "$MP4_FILE" ]; then
            if [ "$_ev" != "bell" ] && [ "$_ev" != "manual" ] && is_low_battery_saver; then
                :
            else
                send_tg_video "$MP4_FILE" "$(build_caption "$_vtitle")" "$_silent" >/dev/null 2>&1
            fi
        fi

        # Battery saver: fast sleep when TG unreachable, low battery, or silent pass-by PIR motion
        if [ -f /tmp/tg_unreachable ]; then
            trim_awake_if_idle 2
        elif [ "$_ev" = "manual" ]; then
            start_poller_if_enabled
        elif [ "$_ev" != "bell" ]; then
            if is_low_battery_saver; then
                trim_awake_if_idle 2
            elif [ "${TG_POLL_ON_DEVICE:-1}" = "1" ]; then
                trim_awake_if_idle 6
            else
                trim_awake_if_idle 2
            fi
            start_poller_if_enabled
        else
            start_poller_if_enabled
        fi
        ;;

    --manual-snap)
        SNAP_FILE="${2:-/tmp/web_snap.jpg}"
        if [ -f "$SNAP_FILE" ]; then
            send_tg_photo "$SNAP_FILE" "$(build_caption '📸 СНИМОК С ЭКРАНА ГЛАЗКА')" "false" >/dev/null 2>&1
        fi
        start_poller_if_enabled
        ;;

    --live)
        [ -f /tmp/force_sleep_now ] && exit 0
        if [ "${TG_POLL_ON_DEVICE:-1}" = "1" ]; then
            touch /tmp/eye_user_active
            extend_awake "${KEEP_AWAKE_SEC:-35}"
            if /app/bin/eye_snap /tmp/tg_live.jpg "${CAM_ROTATE:-90}" 3500; then
                send_mqtt_snapshot /tmp/tg_live.jpg "live"
                send_tg_photo /tmp/tg_live.jpg "$(build_caption '📡 ПРОБУЖДЕНИЕ ГЛАЗКА')" "false" >/dev/null 2>&1
            else
                send_screen_card "main" >/dev/null 2>&1
            fi
            start_poller_if_enabled
        else
            [ -f /tmp/force_sleep_now ] || extend_awake 15
        fi
        ;;

    --test)
        touch /tmp/eye_user_active
        extend_awake 60
        if /app/bin/eye_snap /tmp/tg_test.jpg "${CAM_ROTATE:-90}" 3000; then
            send_tg_photo /tmp/tg_test.jpg "$(build_caption '✅ ТЕСТ КАМЕРЫ ГЛАЗКА')" "false" >/dev/null 2>&1
        fi
        RES=""
        for _cid in $(tg_chat_list); do
            ensure_reply_menu "$_cid"
            RES=$(send_screen_card "main" "$_cid")
        done
        start_poller_if_enabled
        printf "%s" "$RES"
        ;;
esac
