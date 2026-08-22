<#
.SYNOPSIS
  Flash a super.img (ported or stock rollback) to a OnePlus 9 Pro (lemonadep).

.DESCRIPTION
  Sequence follows the BrinaOS flow proven on this device, with explicit _a/_b
  slot targeting instead of the OPlus-specific *_ab shorthand.

  WIPES USERDATA AND METADATA. Switches the active slot (-Slot, default b).

.EXAMPLE
  .\flash-op9p.ps1 -Super \\wsl.localhost\Ubuntu-26.04\home\brina\hp13\out\super.img
.EXAMPLE
  .\flash-op9p.ps1 -Super ...\out_stock\super.img -Label "OOS14 rollback"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Super,
    [string]$FwDir   = '\\wsl.localhost\Ubuntu-26.04\home\brina\hp13\work\_inputs\stock_fw_patched',
    [string]$Stage   = 'C:\Users\gameb\op9p-port\stage',
    [string]$Label   = 'HyperOS port',
    [ValidateSet('a', 'b')][string]$Slot = 'b',
    [switch]$NoCopy,          # flash straight from the UNC path (slower)
    [switch]$KeepData,        # skip userdata/metadata erase
    [switch]$SuperOnly,       # skip boot/dtbo/vendor_boot/vbmeta (already flashed)
    [switch]$Force            # skip the confirmation prompt
)

$ErrorActionPreference = 'Stop'
$FB = 'C:\Users\gameb\AppData\Local\Android\Sdk\platform-tools\fastboot.exe'

function Say  ($m) { Write-Host $m -ForegroundColor Cyan }
function Warn ($m) { Write-Host $m -ForegroundColor Yellow }
function Die  ($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function FB {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$FbArgs)
    Write-Host "  + fastboot $($FbArgs -join ' ')" -ForegroundColor DarkGray
    & $FB @FbArgs 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { Die "fastboot $($FbArgs -join ' ') failed (exit $LASTEXITCODE)" }
}

function GetVar ($name) {
    $out = & $FB getvar $name 2>&1 | Out-String
    if ($out -match "$([regex]::Escape($name)):\s*(\S+)") { return $Matches[1] }
    return $null
}

# ---------------------------------------------------------------- preflight
if (-not (Test-Path $FB))    { Die "fastboot.exe not found at $FB" }
if (-not (Test-Path $Super)) { Die "super image not found: $Super" }

Say "== preflight =="
$devices = (& $FB devices 2>&1 | Out-String).Trim()
if (-not $devices) { Die 'no fastboot device detected. Is the phone in bootloader mode?' }
Write-Host "  device : $devices"

$product = GetVar 'product'
$unlocked = GetVar 'unlocked'
$curSlot  = GetVar 'current-slot'
Write-Host "  product: $product"
Write-Host "  unlocked: $unlocked"
Write-Host "  current-slot: $curSlot"

if ($product -ne 'lahaina') { Die "expected product 'lahaina' (OnePlus 9 Pro), got '$product'. Refusing." }
if ($unlocked -ne 'yes')    { Die 'bootloader is locked. Unlock before flashing.' }

$superSize = (Get-Item $Super).Length
Write-Host ("  super.img: {0:N0} bytes ({1:N2} GiB)" -f $superSize, ($superSize / 1GB))
if ($superSize -ne 11190403072) {
    Warn "  note: super.img is not exactly 11190403072 bytes (the OP9P super size)."
}

foreach ($f in 'boot.img', 'dtbo.img', 'vendor_boot.img', 'vbmeta.img', 'vbmeta_system.img', 'vbmeta_vendor.img') {
    if (-not (Test-Path (Join-Path $FwDir $f))) { Die "missing firmware image: $FwDir\$f" }
}

# ---------------------------------------------------------------- confirm
Write-Host ''
Warn "About to flash: $Label"
Warn "  super  : $Super"
Warn "  fw dir : $FwDir"
if (-not $KeepData) { Warn '  THIS ERASES USERDATA AND METADATA (full data wipe).' }
Warn "  Active slot will be set to $Slot."
Write-Host ''
if (-not $Force) {
    $ans = Read-Host "Type FLASH to continue"
    if ($ans -ne 'FLASH') { Say 'aborted, nothing was written.'; exit 0 }
}

# ---------------------------------------------------------------- stage
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

# Staging cache identity. Size alone is NOT enough: the ported super, the stock
# rollback super, the patched vbmeta and the stock vbmeta are each byte-identical
# in SIZE to their counterpart, so a size-keyed cache silently reuses the wrong
# image while the log claims the right one. Key on source path + size + mtime.
function StageId ($srcPath) {
    $i = Get-Item -LiteralPath $srcPath
    return "{0}|{1}|{2}" -f $i.FullName, $i.Length, $i.LastWriteTimeUtc.Ticks
}
function StageFile ($srcPath, $dstPath) {
    $meta = "$dstPath.stageid"
    $want = StageId $srcPath
    if ((Test-Path $dstPath) -and (Test-Path $meta) -and ((Get-Content $meta -Raw).Trim() -eq $want)) {
        return $false   # already staged, identical source
    }
    Copy-Item -LiteralPath $srcPath -Destination $dstPath -Force
    Set-Content -Path $meta -Value $want -NoNewline
    return $true
}

if (-not $NoCopy) {
    $local = Join-Path $Stage 'super.img'
    Say "== staging super.img locally (avoids a slow 10 GB read over the WSL share) =="
    if (StageFile $Super $local) { Write-Host "  copied 10 GB" }
    else { Write-Host "  reused cached copy (same source, size and mtime)" }
    $Super = $local
    Write-Host "  using $local"
}

# vbmeta must be staged locally even when -NoCopy is set. With
# --disable-verity/--disable-verification, fastboot reads and rewrites the AVB
# header in memory, and that read path fails on \\wsl.localhost UNC paths with
# "Failed to find AVB_MAGIC at offset: 0" even though the image is valid.
# A plain `fastboot flash` streams fine, which is why boot/dtbo succeed there.
Say '== staging firmware images locally =='
$fwLocal = Join-Path $Stage 'fw'
New-Item -ItemType Directory -Force -Path $fwLocal | Out-Null
foreach ($f in 'boot.img', 'dtbo.img', 'vendor_boot.img', 'vbmeta.img', 'vbmeta_system.img', 'vbmeta_vendor.img') {
    [void](StageFile (Join-Path $FwDir $f) (Join-Path $fwLocal $f))
}
$FwDir = $fwLocal
Write-Host "  using $fwLocal"

# sanity: AVB0 magic plus flags==3 (hashtree + verification disabled).
# flags is a big-endian uint32 at offset 120; byte 123 is its low byte.
foreach ($f in 'vbmeta.img', 'vbmeta_system.img', 'vbmeta_vendor.img') {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $FwDir $f))
    $magic = [System.Text.Encoding]::ASCII.GetString($bytes[0..3])
    if ($magic -ne 'AVB0') { Die "$f has no AVB0 magic (got '$magic') - refusing to flash" }
    $flags = ([uint32]$bytes[120] -shl 24) -bor ([uint32]$bytes[121] -shl 16) -bor
             ([uint32]$bytes[122] -shl 8)  -bor  [uint32]$bytes[123]
    # flags=0 is stock/signed; flags=3 is verity+verification disabled.
    # Both are accepted by abl on this device - the BrinaOS ColorOS 16 package
    # ships flags=3 and boots. What actually matters is that the whole boot chain
    # (boot/dtbo/vendor_boot/vbmeta) comes from the SAME build as the critical
    # firmware already on the device; mixing generations is what fails.
    if     ($flags -eq 0) { Write-Host ("  {0} : AVB0 ok, flags=0x00000000 (stock signed)" -f $f) }
    elseif ($flags -eq 3) { Write-Host ("  {0} : AVB0 ok, flags=0x00000003 (verity disabled)" -f $f) }
    else                  { Die ("{0} unexpected flags=0x{1:x8}" -f $f, $flags) }
}

# ---------------------------------------------------------------- flash
Say '== clearing any pending virtual A/B snapshot =='
& $FB snapshot-update cancel 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

Say '== erasing super and re-entering bootloader =='
FB erase super
FB reboot bootloader

Say '   waiting for the device to re-enumerate...'
$deadline = (Get-Date).AddSeconds(120)
do {
    Start-Sleep -Seconds 2
    $seen = (& $FB devices 2>&1 | Out-String).Trim()
    if ($seen) { Write-Host "   back: $seen"; break }
} while ((Get-Date) -lt $deadline)
if (-not $seen) { Die 'device did not come back to bootloader within 120s' }
Start-Sleep -Seconds 2

if ($SuperOnly) {
    Say '== skipping boot/vbmeta (-SuperOnly) =='
} else {

Say '== boot / dtbo / vendor_boot (both slots) =='
foreach ($s in 'a', 'b') {
    FB flash "boot_$s"        (Join-Path $FwDir 'boot.img')
    FB flash "dtbo_$s"        (Join-Path $FwDir 'dtbo.img')
    FB flash "vendor_boot_$s" (Join-Path $FwDir 'vendor_boot.img')
}

# The images are PRE-PATCHED with flags=0x03 (hashtree+verification disabled),
# so these are plain flashes. Do NOT add --disable-verity/--disable-verification:
# fastboot 37.0.0 dies with "Failed to find AVB_MAGIC at offset: 0" on these
# images even though the AVB0 header is valid and the file is local.
Say '== vbmeta (both slots) =='
foreach ($s in 'a', 'b') {
    FB flash "vbmeta_$s"        (Join-Path $FwDir 'vbmeta.img')
    FB flash "vbmeta_system_$s" (Join-Path $FwDir 'vbmeta_system.img')
    FB flash "vbmeta_vendor_$s" (Join-Path $FwDir 'vbmeta_vendor.img')
}

}   # end -SuperOnly guard

Say '== super (this is the long one) =='
FB flash super $Super

if (-not $KeepData) {
    Say '== wiping userdata =='
    # userdata is f2fs; erase is fine, init/vold formats it on first boot.
    FB erase userdata
}

# /metadata must always be a valid ext4 filesystem: first-stage init mounts it
# on a virtual-A/B device for FBE keys and snapshot state. `erase` leaves it raw
# (fastboot even warns "Did you mean to fastboot format this ext4 partition?"),
# so format it explicitly every time, independent of -KeepData.
Say '== formatting metadata (ext4) =='
FB format metadata

Say "== setting active slot to $Slot =="
FB set_active $Slot

Say '== rebooting =='
FB reboot

# First-boot settings.
#
# HyperOS defaults the panel to 60 Hz via config_defaultRefreshRate in
# /product/overlay/FrameworksResCommon_Sys.apk. That overlay maps 57 framework
# resources, so removing it to change one integer is not worth it, and patching
# a signed APK breaks its signature. Settings.System wins over the resource
# default, and it lives in userdata -- which this script wipes -- so apply it
# once per flash instead. ro.adb.secure=0 (set by the port) means adb
# authorises itself, so this needs no interaction.
$adb = Join-Path (Split-Path $FB) 'adb.exe'
if (Test-Path $adb) {
    Say '== waiting for boot to apply first-boot settings =='
    & $adb wait-for-device 2>&1 | Out-Null
    $ok = $false
    foreach ($i in 1..40) {
        Start-Sleep -Seconds 10
        $bc = (& $adb shell getprop sys.boot_completed 2>&1 | Out-String).Trim()
        if ($bc -eq '1') { $ok = $true; break }
        Write-Host "  still booting ($($i * 10)s)..." -ForegroundColor DarkGray
    }
    if ($ok) {
        & $adb shell settings put system peak_refresh_rate 120 2>&1 | Out-Null
        & $adb shell settings put system min_refresh_rate 60   2>&1 | Out-Null
        $rate = (& $adb shell dumpsys SurfaceFlinger 2>&1 | Select-String -Pattern 'renderRate=' | Select-Object -First 1)
        Write-Host "  refresh rate: $($rate -replace '.*renderRate=', '')" -ForegroundColor Green
    } else {
        Warn '  device did not report boot_completed; set refresh rate manually in Settings.'
    }
}

Write-Host ''
Say "done: $Label flashed."
Write-Host 'First boot after a port can take several minutes. If it does not boot,'
Write-Host 'collect evidence before changing anything:'
Write-Host '  adb logcat > logcat.txt      (if adb comes up)'
Write-Host '  fastboot getvar current-slot (confirm it stayed on a)'
Write-Host 'Rollback: re-run this script with the stock super.img from out_stock/.'
