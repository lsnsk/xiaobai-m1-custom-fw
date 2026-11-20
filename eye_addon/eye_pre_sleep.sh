#!/bin/sh
# Pre-sleep hook invoked by main_app cave5_va before MCU sleep when MI_CLOUD_ENABLE=0 & Eco=0
. /app/eye/lib.sh
load_eye_conf

rm -f /tmp/wowlan_ready
save_bat_cache >/dev/null 2>&1 || true
mark_clean_reboot
is_wifi_connected || exit 1
send_mqtt_telemetry_sync "sleep" >/dev/null 2>&1 || true

# Stop background network clients so CYW43438 TX queue is idle for dhd_wait_idle(500)
killall -9 curl ntpd udhcpc 2>/dev/null || true

# Save current IP/gateway/ARP in NVRAM for fast (<1s) warm wake via /app/bin/recovery 1
/app/bin/recovery 0 >/dev/null 2>&1 || true

# Clear preloaded DHCP/mDNS/unicast filters (100..109) and program CYW43438 WoWLAN filters (101..109) & heartbeats
apply_wowlan pre_sleep

# Tolerate brief 2.4GHz beacon fades during 1s DTIM skip and enable PM2 retention before suspend
/app/bin/wl bcn_timeout 20 >/dev/null 2>&1 || true
/app/bin/wl pm2_sleep_ret 80 >/dev/null 2>&1 || true
touch /tmp/wowlan_ready
echo "setsleep" > /proc/cywdhd 2>/dev/null || true
exit 0
