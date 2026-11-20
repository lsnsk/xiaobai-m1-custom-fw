#!/bin/sh
CONF="/etc/eye-bot.conf"
[ -f "$CONF" ] && . "$CONF"

EYE_IP="${EYE_IP:-}"
EYE_MAC="${EYE_MAC:-}"
EYE_IFACE="${EYE_IFACE:-${EYE_LAN_IF:-br-lan}}"
EYE_BROADCAST="${EYE_BROADCAST:-255.255.255.255}"
EYE_WEB_PORT="${EYE_WEB_PORT:-8080}"
WOWLAN_PORT="${WOWLAN_PORT:-9999}"
WOWLAN_KEY="${WOWLAN_KEY:-WAKEUP}"
CACHE_JSON="/tmp/eye_last_status.json"
BAT_FILE="/etc/eye-bot.bat"

if [ -z "$EYE_IP" ]; then
    logger -t eye-keepalive "skip_no_eye_ip (set EYE_IP in $CONF)"
    exit 1
fi

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

_cbat=$(get_cached_bat)
case "$_cbat" in
    ''|*[!0-9]*) ;;
    *)
        if [ "$_cbat" -gt 0 ] && [ "$_cbat" -lt 25 ]; then
            logger -t eye-keepalive "skip_low_bat (${_cbat}%)"
            exit 0
        fi
        ;;
esac

if [ -n "$EYE_MAC" ]; then
    ip neigh replace "$EYE_IP" lladdr "$EYE_MAC" nud permanent dev "$EYE_IFACE" 2>/dev/null || true
fi

_st=$(curl -sS --connect-timeout 2 --max-time 10 "http://${EYE_IP}:${EYE_WEB_PORT}/cgi-bin/api.cgi?action=status" 2>/dev/null || true)
if printf "%s" "$_st" | grep -q '"ok":true'; then
    save_status_cache "$_st"
    logger -t eye-keepalive "awake_ok"
    exit 0
fi

_i=0
while [ "$_i" -lt 6 ]; do
    printf "%s" "$WOWLAN_KEY" | socat -T 1 - "UDP4-DATAGRAM:${EYE_BROADCAST}:${WOWLAN_PORT},broadcast" >/dev/null 2>&1 || true
    printf "%s" "$WOWLAN_KEY" | socat -T 1 - "UDP4-DATAGRAM:${EYE_IP}:${WOWLAN_PORT}" >/dev/null 2>&1 || true
    _st=$(curl -sS --connect-timeout 2 --max-time 10 "http://${EYE_IP}:${EYE_WEB_PORT}/cgi-bin/api.cgi?action=status&wake=1" 2>/dev/null || true)
    if printf "%s" "$_st" | grep -q '"ok":true'; then
        # Wait up to 6s for main_app to finish mounting SD and sampling live MCU ADC battery %
        _bw=0
        while [ "$_bw" -lt 6 ]; do
            if printf "%s" "$_st" | grep -q '"bat_live":true'; then
                break
            fi
            sleep 1
            _st2=$(curl -sS --connect-timeout 2 --max-time 10 "http://${EYE_IP}:${EYE_WEB_PORT}/cgi-bin/api.cgi?action=status" 2>/dev/null || true)
            if printf "%s" "$_st2" | grep -q '"ok":true'; then
                _st="$_st2"
            fi
            _bw=$((_bw + 1))
        done
        save_status_cache "$_st"
        _lbat=$(jsonfilter -i "$CACHE_JSON" -e '@.bat' 2>/dev/null)
        curl -sS --connect-timeout 2 --max-time 5 "http://${EYE_IP}:${EYE_WEB_PORT}/cgi-bin/api.cgi?action=sleep" >/dev/null 2>&1 || true
        logger -t eye-keepalive "wake_and_sleep_ok (bat=${_lbat:-?}%)"
        exit 0
    fi
    sleep 1
    _i=$((_i + 1))
done

logger -t eye-keepalive "wake_timeout"
