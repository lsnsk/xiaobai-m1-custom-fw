#!/bin/sh
# Wakelock manager daemon: keeps peephole awake until /tmp/eye_wake_until (hard-capped at 300s), then releases max_client=0

. /app/eye/lib.sh

echo $$ > /var/run/eye_daemon.pid
_holding=0

while :; do
    if [ -f /tmp/eye_wake_until ]; then
        _until=$(cat /tmp/eye_wake_until 2>/dev/null || echo 0)
        _now=$(get_uptime_s)
        case "$_until" in
            ''|*[!0-9]*) _until=0 ;;
        esac
        if [ $((_until - _now)) -gt 300 ]; then
            _until=$((_now + 300))
            echo "$_until" > /tmp/eye_wake_until
        fi
        if [ "$_now" -lt "$_until" ]; then
            if [ "$_holding" -eq 0 ]; then
                mortoxc set mem default max_client 1 >/dev/null 2>&1 || true
                _holding=1
            fi
        else
            rm -f /tmp/eye_wake_until
            if [ "$_holding" -eq 1 ]; then
                /app/bin/recovery 0 >/dev/null 2>&1 || true
                mortoxc set mem default max_client 0 >/dev/null 2>&1 || true
                _holding=0
            fi
        fi
    elif [ "$_holding" -eq 1 ]; then
        mortoxc set mem default max_client 0 >/dev/null 2>&1 || true
        _holding=0
    fi
    sleep 1
done
