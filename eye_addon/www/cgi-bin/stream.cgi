#!/bin/sh
# Live MJPEG Video Streamer for Xiaobai M1 Web Portal (/app/eye/www/cgi-bin/stream.cgi)
# Zero-HLS/WebRTC CPU overhead: streams rotated 9:16 JPEG frames via multipart/x-mixed-replace.
# Auto-stops on client disconnect or after ~2 minutes (450 frames) to protect the battery.

. /app/eye/lib.sh
load_eye_conf

PID_FILE="/tmp/mjpeg_stream.pid"
if [ -f "$PID_FILE" ]; then
    _old=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$_old" ] && [ "$_old" != "$$" ] && kill -0 "$_old" 2>/dev/null; then
        kill "$_old" 2>/dev/null || true
    fi
fi
echo $$ > "$PID_FILE"

cleanup() {
    [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE"
    rm -f "/tmp/mjpeg_$$.jpg"
}
trap 'cleanup; exit 0' INT TERM HUP PIPE EXIT

ROT="${CAM_ROTATE:-90}"
FRAME="/tmp/mjpeg_$$.jpg"

printf "Content-Type: multipart/x-mixed-replace; boundary=eyeframe\r\n"
printf "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n"
printf "Pragma: no-cache\r\n\r\n" || exit 0

extend_awake 30

_n=0
while [ "$_n" -lt 450 ]; do
    if [ $((_n % 15)) -eq 0 ]; then
        extend_awake 25
    fi
    if /app/bin/eye_snap "$FRAME" "$ROT" 1500 >/dev/null 2>&1 && [ -f "$FRAME" ]; then
        _sz=$(wc -c < "$FRAME" 2>/dev/null | tr -d ' ')
        if [ -n "$_sz" ] && [ "$_sz" -gt 0 ]; then
            printf -- "--eyeframe\r\nContent-Type: image/jpeg\r\nContent-Length: %s\r\n\r\n" "$_sz" || break
            cat "$FRAME" || break
            printf "\r\n" || break
        fi
    fi
    _n=$((_n + 1))
    usleep 200000 2>/dev/null || sleep 1
done
