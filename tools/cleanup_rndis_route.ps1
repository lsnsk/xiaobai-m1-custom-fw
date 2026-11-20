$ErrorActionPreference = "SilentlyContinue"
Remove-NetRoute -DestinationPrefix "192.168.0.1/32" -Confirm:$false
Get-NetIPAddress -IPAddress "192.168.0.2" | Remove-NetIPAddress -Confirm:$false
arp.exe -d 192.168.0.1 2>$null
exit 0
