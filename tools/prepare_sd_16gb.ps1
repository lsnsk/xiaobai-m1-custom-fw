$ErrorActionPreference = "Stop"

# Auto-elevate to Administrator if needed
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

function Fail-And-Pause {
    param([string]$Message)
    Write-Host ""
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host " Xiaobai Smart Cat Eye M1 (CMMY18A) - Safe FAT32 64KB SD Prep" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host ""

    $usbDisks = @(Get-Disk | Where-Object { $_.BusType -eq "USB" -and $_.Number -ne 0 -and $_.Size -gt 0 })
    if ($usbDisks.Count -eq 0) {
        Fail-And-Pause "No USB storage devices found. Insert your microSD card via USB card reader and try again."
    }

    Write-Host "Detected USB disks:" -ForegroundColor Yellow
    foreach ($d in $usbDisks) {
        $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter):" })
        $lStr = if ($letters.Count -gt 0) { $letters -join ", " } else { "(no letter)" }
        $gb = [math]::Round($d.Size / 1GB, 2)
        Write-Host ("  Disk {0}: {1}  |  {2} GB  |  Letters: {3}" -f $d.Number, $d.FriendlyName, $gb, $lStr)
    }

    Write-Host ""
    $pickRaw = Read-Host "Enter the USB Disk Number of your microSD card (or press Enter to cancel)"
    if (-not $pickRaw -or ($pickRaw -notmatch '^\d+$')) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 0
    }
    $diskNum = [int]$pickRaw
    $disk = $usbDisks | Where-Object { $_.Number -eq $diskNum } | Select-Object -First 1
    if (-not $disk) {
        Fail-And-Pause "Disk $diskNum is not in the USB disk list above. Aborting for safety."
    }
    if ($disk.Size -gt 300000000000) {
        Fail-And-Pause ("Disk {0} is {1} GB (> 300 GB) -- looks like a USB HDD/SSD, not a microSD card! Aborting." -f $diskNum, [math]::Round($disk.Size / 1GB, 1))
    }

    $sizeGb = [math]::Round($disk.Size / 1GB, 2)
    Write-Host ""
    Write-Host ("WARNING: ALL DATA ON Disk {0} ({1}, {2} GB) WILL BE ERASED!" -f $diskNum, $disk.FriendlyName, $sizeGb) -ForegroundColor Red
    $confirm = Read-Host "Type FORMAT to confirm"
    if ($confirm -ne "FORMAT") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 0
    }

    $createLine = if ($disk.Size -gt 18000000000) { "create partition primary size=16384" } else { "create partition primary" }
    $dpLines = @(
        "select disk $diskNum",
        "clean",
        $createLine,
        "select partition 1",
        "format fs=fat32 unit=64K label=IPC018 quick",
        "set id=0b override",
        "assign",
        "exit"
    )
    $dpFile = Join-Path $env:TEMP "ipc018_prepare_sd_diskpart.txt"
    $dpLines | Set-Content -Path $dpFile -Encoding ASCII

    Write-Host ""
    Write-Host "[1/3] Formatting Disk $diskNum as FAT32 (64KB cluster, MBR 0x0B)..." -ForegroundColor Cyan
    diskpart /s $dpFile
    if ($LASTEXITCODE -ne 0) {
        Fail-And-Pause "diskpart exited with code $LASTEXITCODE."
    }

    $driveLetter = $null
    for ($i = 0; $i -lt 30; $i++) {
        $p1 = Get-Partition -DiskNumber $diskNum -PartitionNumber 1 -ErrorAction SilentlyContinue
        if ($p1 -and $p1.DriveLetter) {
            $driveLetter = [string]$p1.DriveLetter
            if (Test-Path -LiteralPath "${driveLetter}:\") {
                break
            }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $driveLetter) {
        Fail-And-Pause "Could not detect assigned drive letter for Disk $diskNum Partition 1."
    }
    $rootPath = "${driveLetter}:\"
    Write-Host ("[OK] Formatted volume mounted at {0}" -f $rootPath) -ForegroundColor Green

    Write-Host "[2/3] Verifying FAT32, 64KB cluster (65536 B), and MBR type 0x0B (11)..." -ForegroundColor Cyan
    $vol = Get-CimInstance Win32_Volume -Filter ("DriveLetter='{0}:'" -f $driveLetter)
    if ($null -eq $vol -or $vol.FileSystem -ne "FAT32" -or [int64]$vol.BlockSize -ne 65536) {
        Fail-And-Pause ("Volume check failed on {0}: FileSystem={1}, BlockSize={2}" -f $rootPath, $vol.FileSystem, $vol.BlockSize)
    }
    $part = Get-Partition -DriveLetter $driveLetter
    if ($null -eq $part -or [int]$part.MbrType -ne 11) {
        Fail-And-Pause ("Partition check failed on {0}: MbrType={1} (expected 11 / 0x0B)" -f $rootPath, $part.MbrType)
    }
    Write-Host "[OK] FAT32 + 64KB cluster + MBR 0x0B verified!" -ForegroundColor Green

    Write-Host "[3/3] Checking for firmware / unbrick files next to script..." -ForegroundColor Cyan
    $unbrickImg = Join-Path $scriptDir "tf_update.img"
    $patchDir = $null
    if (Test-Path -LiteralPath (Join-Path $scriptDir "patch_435\MD5SUMS.txt")) {
        $patchDir = Join-Path $scriptDir "patch_435"
    } elseif (Test-Path -LiteralPath (Join-Path $scriptDir "MD5SUMS.txt")) {
        $patchDir = $scriptDir
    }

    if (Test-Path -LiteralPath $unbrickImg) {
        Write-Host "  Found tf_update.img -> staging UNBRICK card on $rootPath..." -ForegroundColor Yellow
        Copy-Item -LiteralPath $unbrickImg -Destination (Join-Path $rootPath "tf_update.img") -Force
        $srcHash = (Get-FileHash -LiteralPath $unbrickImg -Algorithm MD5).Hash.ToUpperInvariant()
        $dstHash = (Get-FileHash -LiteralPath (Join-Path $rootPath "tf_update.img") -Algorithm MD5).Hash.ToUpperInvariant()
        if ($srcHash -ne $dstHash) {
            Fail-And-Pause "MD5 mismatch after copying tf_update.img!"
        }
        Write-Host ("  MD5 OK: tf_update.img = {0}" -f $dstHash) -ForegroundColor Gray
        Write-VolumeCache -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "[SUCCESS] UNBRICK SD card is ready on $rootPath!" -ForegroundColor Green
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Safely eject $rootPath and UNPLUG USB cable from the peephole (important: USB connected enters BootROM instead of SD flash!)."
        Write-Host "  2. Insert the SD card into the peephole (battery >= 30%)."
        Write-Host "  3. Hold BOTH Power + Home buttons together for 6-8 seconds, then release (at ~4s MCU hard-reboots SoC and pulls GPIO0_0 LOW for U-Boot)."
        Write-Host "  4. Wait ~2-3 minutes for U-Boot to flash tf_update.img and reboot, then delete tf_update.img from the SD card!"
    } elseif ($patchDir) {
        Write-Host "  Found firmware bundle in $patchDir -> staging patch_435 + IPC018_TESTMODE.file..." -ForegroundColor Yellow
        New-Item -Path (Join-Path $rootPath "IPC018_TESTMODE.file") -ItemType File -Force | Out-Null
        $dstPatch = Join-Path $rootPath "patch_435"
        New-Item -Path $dstPatch -ItemType Directory -Force | Out-Null

        $md5File = Join-Path $patchDir "MD5SUMS.txt"
        $expectedHashes = @{}
        foreach ($line in (Get-Content -LiteralPath $md5File)) {
            $trim = $line.Trim()
            if ($trim -match '^([0-9a-fA-F]{32})\s+(\S+)$') {
                $expectedHashes[$Matches[2]] = $Matches[1].ToUpperInvariant()
            }
        }
        foreach ($fn in @("media_app_zip.bin", "uImage.bin", "rootfs.squashfs", "MD5SUMS.txt")) {
            $sp = Join-Path $patchDir $fn
            if (Test-Path -LiteralPath $sp) {
                Copy-Item -LiteralPath $sp -Destination (Join-Path $dstPatch $fn) -Force
            }
        }
        foreach ($fn in $expectedHashes.Keys) {
            $dp = Join-Path $dstPatch $fn
            if (-not (Test-Path -LiteralPath $dp)) {
                Fail-And-Pause "Missing staged file: $dp"
            }
            $ah = (Get-FileHash -LiteralPath $dp -Algorithm MD5).Hash.ToUpperInvariant()
            if ($ah -ne $expectedHashes[$fn]) {
                Fail-And-Pause ("MD5 mismatch for {0}: got {1}, expected {2}" -f $fn, $ah, $expectedHashes[$fn])
            }
            Write-Host ("  MD5 OK: {0} = {1}" -f $fn, $ah) -ForegroundColor Gray
        }

        $confEx = Join-Path $scriptDir "eye.conf.example"
        if (-not (Test-Path -LiteralPath $confEx)) {
            $confEx = Join-Path $patchDir "eye.conf.example"
        }
        if (Test-Path -LiteralPath $confEx) {
            Copy-Item -LiteralPath $confEx -Destination (Join-Path $rootPath "eye.conf.example") -Force
            Copy-Item -LiteralPath $confEx -Destination (Join-Path $rootPath "eye.conf") -Force
            Write-Host "  Copied eye.conf (edit WIFI_SSID / WIFI_PASS / TG_BOT_TOKEN on $rootPath)." -ForegroundColor Gray
        }
        Write-VolumeCache -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "[SUCCESS] Firmware SD card is ready on $rootPath!" -ForegroundColor Green
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Edit ${rootPath}eye.conf (optional - can also edit later via Web UI) and safely eject $rootPath."
        Write-Host "  2. Keep USB UNPLUGGED and insert SD into the peephole."
        Write-Host "  3. Enter Test Mode:"
        Write-Host "     - On STOCK firmware: open Settings -> Page 3 (About), tap 5x within 4s (Row1-Left -> Row1-Right -> Row2-Left -> Row2-Right -> Row3), then tap 'TEST MODE' button in bottom row and wait ~10-12s."
        Write-Host "     - On OUR patched 4.3.5_3319: just reboot on battery (IPC018_TESTMODE.file triggers Test Mode automatically) and wait ~10-12s until blank backlit screen."
        Write-Host "  4. Connect Micro-USB to PC, run connect_rndis.bat, then run: python install_firmware.py"
        Write-Host "  5. Unplug USB and run cleanup_rndis_route.ps1."
    } else {
        Write-VolumeCache -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "[SUCCESS] Clean 16GB FAT32 (64KB cluster, MBR 0x0B) SD card is ready on $rootPath!" -ForegroundColor Green
    }
}
catch {
    Fail-And-Pause $_.Exception.Message
}

Read-Host "Press Enter to close"
