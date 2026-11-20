param(
    [string]$RouterHost = "192.168.0.1",
    [string]$RouterUser = "root",
    [string]$IdentityFile = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$botSrc = Join-Path $scriptDir "eye_openwrt_bot.sh"
$keepSrc = Join-Path $scriptDir "eye_keepalive.sh"

foreach ($p in @($botSrc, $keepSrc)) {
    if (-not (Test-Path $p)) {
        throw "Missing file: $p"
    }
    $bytes = [System.IO.File]::ReadAllBytes($p)
    for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
        if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10) {
            throw "CRLF detected in $p -- convert to LF before deploying."
        }
    }
}

$lanIp = $null
$prefix = ($RouterHost -replace '\.\d+$', '.')
$cand = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress.StartsWith($prefix) -and $_.IPAddress -ne "192.168.0.2" } |
    Select-Object -First 1
if ($cand) {
    $lanIp = $cand.IPAddress
}

$sshOpts = @("-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new")
if ($lanIp) {
    $sshOpts += @("-o", "BindAddress=$lanIp")
    Write-Host "[*] Using LAN source IP $lanIp -> $RouterUser@$RouterHost" -ForegroundColor Cyan
} else {
    Write-Host "[*] Target: $RouterUser@$RouterHost" -ForegroundColor Cyan
}
if ($IdentityFile -and (Test-Path $IdentityFile)) {
    $sshOpts += @("-i", $IdentityFile)
}

Write-Host "[1/2] Uploading eye_openwrt_bot.sh and eye_keepalive.sh to /tmp (enter OpenWrt SSH password if prompted)..." -ForegroundColor Yellow
$scpArgs = @("-O") + $sshOpts + @($botSrc, $keepSrc, "${RouterUser}@${RouterHost}:/tmp/")
& scp @scpArgs
if ($LASTEXITCODE -ne 0) {
    throw "scp failed with exit code $LASTEXITCODE"
}

$remoteCmd = @'
set -e
sh -n /tmp/eye_openwrt_bot.sh
sh -n /tmp/eye_keepalive.sh
cp -f /usr/bin/eye_openwrt_bot.sh /tmp/eye_openwrt_bot.sh.bak 2>/dev/null || true
cp -f /usr/bin/eye_keepalive.sh /tmp/eye_keepalive.sh.bak 2>/dev/null || true
mv -f /tmp/eye_openwrt_bot.sh /usr/bin/eye_openwrt_bot.sh
mv -f /tmp/eye_keepalive.sh /usr/bin/eye_keepalive.sh
chmod 755 /usr/bin/eye_openwrt_bot.sh /usr/bin/eye_keepalive.sh
echo "--- Config check (non-secret keys) ---"
grep -E '^(EYE_IP|EYE_MAC|EYE_IFACE|EYE_LAN_IF|EYE_BROADCAST|WAKE_TIMEOUT_SEC)=' /etc/eye-bot.conf 2>/dev/null || echo "WARN: /etc/eye-bot.conf missing or lacks EYE_IP"
if [ -x /etc/init.d/eye-bot ]; then
    /etc/init.d/eye-bot restart
    sleep 2
fi
echo "--- Installed MD5 ---"
md5sum /usr/bin/eye_openwrt_bot.sh /usr/bin/eye_keepalive.sh
echo "--- Running process ---"
ps w | grep eye_openwrt_bot | grep -v grep || echo "WARN: eye_openwrt_bot.sh not running"
'@
$remoteCmdLf = $remoteCmd -replace "`r`n", "`n"

Write-Host "[2/2] Validating syntax, installing to /usr/bin, and restarting /etc/init.d/eye-bot..." -ForegroundColor Yellow
$sshArgs = $sshOpts + @("${RouterUser}@${RouterHost}", $remoteCmdLf)
& ssh @sshArgs
if ($LASTEXITCODE -ne 0) {
    throw "ssh install step failed with exit code $LASTEXITCODE"
}

Write-Host "[OK] OpenWrt eye-bot scripts updated cleanly (without touching /etc/eye-bot.conf)." -ForegroundColor Green
