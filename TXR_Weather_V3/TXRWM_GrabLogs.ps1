# TXRWM_GrabLogs.ps1 : collect TXR Weather Mod diagnostics into one zip.
# For testers/users: double-click TXRWM_GrabLogs.cmd, send the zip it
# puts on your Desktop. Collects (read-only, changes nothing):
#   - ue4ss\UE4SS.log (overwritten every boot: grab it BEFORE relaunching)
#   - ue4ss\crash_*.dmp (recent; size-capped so the zip stays sendable)
#   - Mods\TXR_Weather_V3\Logs (newest logs + row/state files)
#   - Mods\TXR_Weather_V3\Scripts\config.lua (your settings)
#   - ue4ss\UE4SS-settings.ini + Mods\mods.txt (mod environment)
#   - %LOCALAPPDATA%\TokyoXtremeRacer\Saved\Crashes (engine crash reports)
#   - %LOCALAPPDATA%\TokyoXtremeRacer\Saved\Logs (game logs, if any)
param(
    [string]$GamePath = '',
    [string]$OutDir = '',
    [switch]$Quiet
)
$ErrorActionPreference = 'Continue'
function Say([string]$m, [string]$c) { Write-Host $m -ForegroundColor $c }

Say '================================================' White
Say '  TXR Weather Mod - log grabber' White
Say '================================================' White

# ---- 1) locate the game's Binaries\Win64 ------------------------------------
$exeName = 'TokyoXtremeRacer-Win64-Shipping.exe'
$win64 = $null

if ($GamePath -and (Test-Path (Join-Path $GamePath $exeName))) { $win64 = $GamePath }

if (-not $win64) {
    # walk up from where this script sits (works when dropped anywhere in
    # the game folder, e.g. next to the exe or into ue4ss\)
    $probe = $PSScriptRoot
    for ($i = 0; $i -lt 7; $i++) {
        if (-not $probe) { break }
        if (Test-Path (Join-Path $probe $exeName)) { $win64 = $probe; break }
        $hit = Get-ChildItem $probe -Filter $exeName -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $win64 = $hit.DirectoryName; break }
        $probe = Split-Path $probe -Parent
    }
}

if (-not $win64) {
    # Steam detection
    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        if ($steam) {
            $steam = $steam -replace '/', '\'
            $libs = @($steam)
            $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
            if (Test-Path $vdf) {
                foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                    $libs += ($m.Groups[1].Value -replace '\\\\', '\')
                }
            }
            foreach ($lib in ($libs | Select-Object -Unique)) {
                $cand = Join-Path $lib 'steamapps\common\TokyoXtremeRacer\TokyoXtremeRacer\Binaries\Win64'
                if (Test-Path (Join-Path $cand $exeName)) { $win64 = $cand; break }
            }
        }
    } catch {}
}

while (-not $win64) {
    Say 'Could not find the game automatically.' Yellow
    Say "Paste the path to the game's Binaries\Win64 folder (contains $exeName):" Yellow
    $p = (Read-Host 'Path').Trim().Trim('"')
    if ($p -and (Test-Path (Join-Path $p $exeName))) { $win64 = $p }
    else { Say 'That folder does not contain the game exe. Try again.' Red }
}
Say "Game: $win64" Green

$ue4ss   = Join-Path $win64 'ue4ss'
$modDir  = Join-Path $ue4ss 'Mods\TXR_Weather_V3'
$saved   = Join-Path $env:LOCALAPPDATA 'TokyoXtremeRacer\Saved'

# ---- 2) staging --------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$stage = Join-Path $env:TEMP ("txrwm_logs_$stamp")
foreach ($sub in 'ue4ss', 'modlogs', 'config', 'crashes', 'gamelogs') {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage $sub) | Out-Null
}
$manifest = New-Object System.Collections.Generic.List[string]
$manifest.Add("TXRWM log bundle  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$manifest.Add("Game: $win64")
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $manifest.Add("OS: $($os.Caption) $($os.Version)")
} catch {}
try {
    $cfgRaw = Get-Content (Join-Path $modDir 'Scripts\config.lua') -Raw -ErrorAction Stop
    $vm = [regex]::Match($cfgRaw, 'Config\.Version\s*=\s*\{\s*String\s*=\s*"([^"]+)"')
    if ($vm.Success) { $manifest.Add("Mod version: $($vm.Groups[1].Value)") }
} catch {}
$manifest.Add('')

function Grab([string]$src, [string]$destSub, [string]$note) {
    if (-not (Test-Path -LiteralPath $src)) { return $false }
    try {
        Copy-Item -LiteralPath $src -Destination (Join-Path $stage $destSub) -Recurse -Force
        $i = Get-Item -LiteralPath $src
        $kb = 0; if (-not $i.PSIsContainer) { $kb = [math]::Round($i.Length / 1KB) }
        $manifest.Add(("  {0}  ({1} KB)  {2}" -f $i.Name, $kb, $note))
        return $true
    } catch {
        $manifest.Add("  FAILED: $src ($($_.Exception.Message))")
        return $false
    }
}

# ---- 3) collect --------------------------------------------------------------
Say 'Collecting ue4ss logs...' Cyan
$manifest.Add('[ue4ss]')
Grab (Join-Path $ue4ss 'UE4SS.log') 'ue4ss' 'current/last boot (overwritten each boot)' | Out-Null
Grab (Join-Path $ue4ss 'UE4SS-settings.ini') 'ue4ss' '' | Out-Null
Grab (Join-Path $ue4ss 'Mods\mods.txt') 'ue4ss' 'enabled mods' | Out-Null

# ue4ss crash dumps: all from the last 48h, else the newest one; cap total
$manifest.Add('[ue4ss crash dumps]')
$dumps = @(Get-ChildItem $ue4ss -Filter 'crash_*.dmp' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
$recent = @($dumps | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-48) })
if ($recent.Count -eq 0 -and $dumps.Count -gt 0) { $recent = @($dumps[0]) }
$budget = 150MB
foreach ($d in $recent) {
    if ($budget - $d.Length -lt 0) { $manifest.Add("  SKIPPED (size cap): $($d.Name)"); continue }
    if (Grab $d.FullName 'ue4ss' $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) { $budget -= $d.Length }
}
if ($dumps.Count -eq 0) { $manifest.Add('  (none found)') }

Say 'Collecting mod logs...' Cyan
$manifest.Add('[mod logs]')
$logDir = Join-Path $modDir 'Logs'
if (Test-Path $logDir) {
    foreach ($f in (Get-ChildItem $logDir -Filter '*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 10)) {
        Grab $f.FullName 'modlogs' $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm') | Out-Null
    }
    foreach ($n in 'slab_rows.txt', 'tuning_feedback.log', 'editor_hud.txt') {
        Grab (Join-Path $logDir $n) 'modlogs' '' | Out-Null
    }
}
Grab (Join-Path $modDir 'last_state.txt') 'modlogs' '' | Out-Null

Say 'Collecting config...' Cyan
$manifest.Add('[config]')
Grab (Join-Path $modDir 'Scripts\config.lua') 'config' 'user settings' | Out-Null

Say 'Collecting engine crash reports...' Cyan
$manifest.Add('[engine crashes]')
$crashRoot = Join-Path $saved 'Crashes'
if (Test-Path $crashRoot) {
    foreach ($d in (Get-ChildItem $crashRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
        Grab $d.FullName 'crashes' $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm') | Out-Null
    }
} else { $manifest.Add('  (none found)') }
$gameLogs = Join-Path $saved 'Logs'
if (Test-Path $gameLogs) {
    $manifest.Add('[game logs]')
    foreach ($f in (Get-ChildItem $gameLogs -File | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
        Grab $f.FullName 'gamelogs' '' | Out-Null
    }
}

Set-Content -Path (Join-Path $stage 'MANIFEST.txt') -Value ($manifest -join "`r`n") -Encoding utf8

# ---- 4) zip ------------------------------------------------------------------
if (-not $OutDir) { $OutDir = [Environment]::GetFolderPath('Desktop') }
$zip = Join-Path $OutDir ("TXRWM_logs_$stamp.zip")
Say 'Zipping...' Cyan
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

$zi = Get-Item $zip
Say '' White
Say ("DONE: {0}  ({1:N1} MB)" -f $zip, ($zi.Length / 1MB)) Green
Say 'Send this file to the mod author.' Green
if (-not $Quiet) {
    try { Start-Process explorer.exe "/select,`"$zip`"" } catch {}
    try { Read-Host 'Press Enter to close' } catch {}
}
