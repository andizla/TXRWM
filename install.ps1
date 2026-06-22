# =============================================================================
# TXR Weather Mod V3 - Installer
# -----------------------------------------------------------------------------
# Self-contained: ships as just install.bat + install.ps1.
#   - UE4SS  : downloaded at runtime (CookiePLMonster TXR25 build)
#   - Mod    : downloaded at runtime from $ModUrl (GitHub release zip)
#   - engine.ini : the minimal required cvars are embedded below ($MinIni)
#
# PRE-RELEASE TESTING: leave $ModUrl = '' to install from a local TXR_Weather_V3
# folder placed next to this script instead of downloading.
# =============================================================================

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Root     = $PSScriptRoot
$ModName  = 'TXR_Weather_V3'
$UE4SSUrl = 'https://github.com/CookiePLMonster/UE4SS-Bakery/releases/latest/download/UE4SS-TXR25.zip'

# GitHub release asset. Name the release zip 'TXR_Weather_V3.zip' so this resolves.
# Leave as '' to install from a local TXR_Weather_V3 folder next to this script
# (pre-release testing) - the repo/release don't exist yet as of writing.
$ModUrl   = 'https://github.com/andizla/TXRWM/releases/latest/download/TXR_Weather_V3.zip'

# Minimal required engine.ini (the only cvars the mod needs to function).
$MinIni = @(
    '[ConsoleVariables]',
    'r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange=1',
    'r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange=True',
    'r.EyeAdaptation.MethodOverride=3',
    'r.fog=1',
    'r.Lumen.SampleFog=1',
    'r.NGX.DLSS.AutoExposure=0'
)

# ----- helpers ---------------------------------------------------------------
function Say($m, $c='Gray'){ Write-Host $m -ForegroundColor $c }
function Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "    $m" -ForegroundColor Green }
function Warn($m){ Write-Host "    $m" -ForegroundColor Yellow }

function AskYesNo($q, $default=$true){
    $suffix = if($default){'[Y/n]'} else {'[y/N]'}
    while($true){
        $a = (Read-Host "$q $suffix").Trim()
        if($a -eq ''){ return $default }
        if($a -match '^(y|yes)$'){ return $true }
        if($a -match '^(n|no)$'){ return $false }
        Warn 'Please answer y or n.'
    }
}

# Write lines as UTF-8 without BOM (engine.ini / mods.txt friendly)
function WriteLines($path, $lines){
    [IO.File]::WriteAllLines($path, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
}

function Find-GameWin64 {
    $libs = @()
    $steam = $null
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
    if(-not $steam){ try { $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch {} }
    if($steam){
        $steam = $steam -replace '/','\'
        $libs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if(Test-Path $vdf){
            foreach($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s*"([^"]+)"')){
                $libs += ($m.Groups[1].Value -replace '\\\\','\')
            }
        }
    }
    $hits = @()
    foreach($lib in ($libs | Select-Object -Unique)){
        $common = Join-Path $lib 'steamapps\common\TokyoXtremeRacer'
        if(Test-Path $common){
            $exe = Get-ChildItem -Path $common -Recurse -Filter 'TokyoXtremeRacer-Win64-Shipping.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if($exe){ $hits += $exe.DirectoryName }
        }
    }
    return ($hits | Select-Object -Unique)
}

function Download-Zip($url, $outFile){
    Invoke-WebRequest -Uri $url -OutFile $outFile
}

# Find the actual mod root (the folder containing Scripts\main.lua) inside an
# extracted tree, regardless of how the zip is packed.
function Find-ModRoot($base){
    if(Test-Path (Join-Path $base 'Scripts\main.lua')){ return $base }
    $cand = Get-ChildItem $base -Recurse -Filter 'main.lua' -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq 'Scripts' } | Select-Object -First 1
    if($cand){ return (Split-Path $cand.Directory.FullName -Parent) }
    return $null
}

# Merge our required cvars as a managed block at the END of an existing ini so
# they apply last and win over any conflicting earlier values. Idempotent.
function Merge-Cvars($path, $minLines){
    $marker    = '; === TXR Weather Mod (required cvars) - managed by installer ==='
    $endMarker = '; === end TXR Weather Mod ==='
    $existing  = @(Get-Content $path)
    $out = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach($l in $existing){
        if($l -eq $marker){ $inBlock = $true; continue }
        if($l -eq $endMarker){ $inBlock = $false; continue }
        if(-not $inBlock){ $out.Add($l) }
    }
    $cvars = $minLines | Where-Object { $_ -ne '' -and ($_ -notmatch '^\s*\[') }
    $block = @('', $marker, '[ConsoleVariables]') + $cvars + @($endMarker)
    WriteLines $path ($out + $block)
}

# ----- start -----------------------------------------------------------------
Say "================================================" White
Say "  TXR Weather Mod V3 - Installer" White
Say "  by Ten." White
Say "================================================" White
Say ""
Say "This will set the mod up in 4 steps:" White
Say "  1. Find your Tokyo Xtreme Racer install (auto-detected via Steam)."
Say "  2. Download + install UE4SS - the script loader the mod runs on."
Say "     Any mods you already have are left in place."
Say "  3. Install the weather mod and enable it (mods.txt)."
Say "  4. Set up the small Engine.ini the mod needs for correct exposure/fog."
Say "     Any existing Engine.ini is backed up first, and you choose what happens to it."
Say ""
Say "Nothing on disk is changed until you confirm the location on the next screen." White
Say ""

# 1) Locate the game ----------------------------------------------------------
Step 'Locating Tokyo Xtreme Racer'
$win64 = $null
$found = @(Find-GameWin64)
if($found.Count -ge 1){
    Ok "Detected: $($found[0])"
    if(AskYesNo 'Install to this location?'){ $win64 = $found[0] }
}
while(-not $win64){
    Warn "Paste the path to the game's Binaries\Win64 folder"
    Warn "(the folder that contains TokyoXtremeRacer-Win64-Shipping.exe)"
    $p = (Read-Host 'Path').Trim().Trim('"')
    if($p -and (Test-Path (Join-Path $p 'TokyoXtremeRacer-Win64-Shipping.exe'))){ $win64 = $p }
    else { Warn 'That folder does not contain the game exe. Try again.' }
}
$ue4ss   = Join-Path $win64 'ue4ss'
$modsDir = Join-Path $ue4ss 'Mods'

# Show the concrete plan and get the go-ahead before changing anything ---------
Step 'Ready to install - here is what will happen'
Say "  Location   : $win64"
Say "  UE4SS      : downloaded and installed here (your existing Mods are kept)"
Say "  Mod        : installed to  ue4ss\Mods\$ModName"
Say "  mods.txt   : the mod is added to the UE4SS load list (your other entries are kept)"
Say "  Engine.ini : %LOCALAPPDATA%\TokyoXtremeRacer\Saved\Config\Windows"
Say "               existing file is backed up; you choose Replace / Merge / Skip"
Say ""
if(-not (AskYesNo 'Proceed with installation?')){
    Say ''
    Say 'Cancelled - nothing was changed.' Yellow
    return
}

# temp workspace for downloads
$tmp = Join-Path $env:TEMP ('txrwm_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {

    # 2) UE4SS ----------------------------------------------------------------
    Step 'UE4SS'
    Say '    The script loader the mod runs on. Installs into the game folder;'
    Say '    any UE4SS mods you already have are preserved.'
    $haveUE4SS = (Test-Path (Join-Path $win64 'dwmapi.dll')) -and (Test-Path $ue4ss)
    $installUE4SS = $true
    if($haveUE4SS){
        Warn 'UE4SS is already installed here.'
        $installUE4SS = AskYesNo 'Reinstall/overwrite UE4SS? (your existing Mods are kept)' $false
    }
    if($installUE4SS){
        $ext = Join-Path $tmp 'ue4ss'
        New-Item -ItemType Directory -Force -Path $ext | Out-Null
        $zip = Join-Path $tmp 'ue4ss.zip'
        Ok 'Downloading UE4SS...'
        Download-Zip $UE4SSUrl $zip
        Ok 'Extracting...'
        Expand-Archive -Path $zip -DestinationPath $ext -Force
        $srcDir = $ext
        if(-not (Test-Path (Join-Path $srcDir 'dwmapi.dll'))){
            $sub = Get-ChildItem $ext -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'dwmapi.dll') } | Select-Object -First 1
            if($sub){ $srcDir = $sub.FullName }
        }
        if(-not (Test-Path (Join-Path $srcDir 'dwmapi.dll'))){ throw 'Downloaded UE4SS archive did not contain dwmapi.dll (unexpected layout).' }
        $rc = @($srcDir, $win64, '/E','/NFL','/NDL','/NJH','/NJS','/NP')
        if($haveUE4SS){ $rc += @('/XD','Mods') }   # never clobber an existing Mods folder
        & robocopy @rc | Out-Null
        if($LASTEXITCODE -ge 8){ throw "robocopy failed copying UE4SS (code $LASTEXITCODE)" }
        Ok 'UE4SS installed.'
    }
    New-Item -ItemType Directory -Force -Path $modsDir | Out-Null

    # 3) Mod files (download, or local fallback) ------------------------------
    Step 'Mod files'
    $modRoot = $null
    $localMod = Join-Path $Root $ModName
    $localHasMod = Test-Path (Join-Path $localMod 'Scripts\main.lua')
    if($ModUrl){
        try {
            $ext = Join-Path $tmp 'mod'
            New-Item -ItemType Directory -Force -Path $ext | Out-Null
            $zip = Join-Path $tmp 'mod.zip'
            Ok 'Downloading mod...'
            Download-Zip $ModUrl $zip
            Ok 'Extracting...'
            Expand-Archive -Path $zip -DestinationPath $ext -Force
            $modRoot = Find-ModRoot $ext
            if(-not $modRoot){ throw 'archive did not contain Scripts\main.lua' }
        } catch {
            Warn "Mod download failed: $($_.Exception.Message)"
            if($localHasMod){
                Warn 'Falling back to the local mod folder next to the installer.'
                $modRoot = $localMod
            } else {
                throw "Could not download the mod and no local '$ModName' folder is present next to the installer."
            }
        }
    } elseif($localHasMod){
        Warn 'ModUrl not set - installing from local folder.'
        $modRoot = $localMod
    } else {
        throw "ModUrl is empty and no local '$ModName' folder (with Scripts\main.lua) was found next to the installer."
    }

    $modDst = Join-Path $modsDir $ModName
    if(Test-Path $modDst){
        if(AskYesNo 'Mod already installed. Overwrite (update) it?'){ Remove-Item $modDst -Recurse -Force }
        else { Warn 'Keeping existing mod files.' }
    }
    if(-not (Test-Path $modDst)){
        $rc = @($modRoot, $modDst, '/E','/NFL','/NDL','/NJH','/NJS','/NP','/XD','Logs','.backup','/XF','*.bak')
        & robocopy @rc | Out-Null
        if($LASTEXITCODE -ge 8){ throw "robocopy failed copying the mod (code $LASTEXITCODE)" }
        Ok "Installed mod to $modDst"
    }

    # mods.txt (merge: keep existing entries, add ours if missing)
    Step 'Enabling the mod (mods.txt)'
    Say "    UE4SS reads which mods to load from mods.txt. Merging the mod into it -"
    Say "    your existing entries are left untouched."
    $modsTxt = Join-Path $modsDir 'mods.txt'
    $lines = @()
    if(Test-Path $modsTxt){ $lines = @(Get-Content $modsTxt) }
    if($lines -match "^\s*$ModName\s*:"){
        Ok 'Already listed in mods.txt - left as is.'
    } else {
        $lines += "$ModName : 1"
        WriteLines $modsTxt $lines
        Ok "Added '$ModName : 1' to mods.txt (other entries untouched)."
    }

    # 4) Old standalone VEAO conflict ----------------------------------------
    foreach($veao in @('VEAOV213B','VEAO')){
        $vp = Join-Path $modsDir $veao
        if(Test-Path $vp){
            Warn "Found old standalone '$veao' - it double-applies exposure and fights the merged module."
            if(AskYesNo "Disable '$veao' in mods.txt?"){
                $ml = @(Get-Content $modsTxt)
                if($ml -match "^\s*$veao\s*:"){ $ml = $ml -replace "^\s*$veao\s*:.*", "$veao : 0" }
                else { $ml += "$veao : 0" }
                WriteLines $modsTxt $ml
                Ok "Disabled '$veao'."
            }
        }
    }

    # 5) engine.ini (Replace / Merge / Skip) ---------------------------------
    Step 'Engine.ini (required CVARs)'
    Say '    The mod needs a few console variables (exposure + fog) that live in'
    Say '    Engine.ini - without them the game can look too bright or washed out.'
    Say '    Any existing file is backed up first; it is then made read-only so the'
    Say '    game cannot overwrite it.'
    $cfgDir = Join-Path $env:LOCALAPPDATA 'TokyoXtremeRacer\Saved\Config\Windows'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $iniDst  = Join-Path $cfgDir 'Engine.ini'
    $skipped = $false

    if(Test-Path $iniDst){
        $f = Get-Item $iniDst
        if($f.IsReadOnly){ $f.IsReadOnly = $false }
        $bak = "$iniDst.bak." + (Get-Date -Format 'yyyyMMdd_HHmmss')
        Copy-Item $iniDst $bak
        Ok "Backed up existing Engine.ini -> $(Split-Path $bak -Leaf)"
        Warn 'An Engine.ini already exists.'
        Say  '    [R] Replace with the minimal required file'
        Say  '    [M] Merge - keep yours, add the required cvars at the end (recommended)'
        Say  '    [S] Skip - leave your Engine.ini untouched'
        $choice = (Read-Host '    Choice [R/M/S]').Trim()
        switch -Regex ($choice){
            '^[Rr]' { WriteLines $iniDst $MinIni; Ok 'Replaced with minimal Engine.ini.' }
            '^[Mm]' { Merge-Cvars $iniDst $MinIni; Ok 'Merged required cvars at end of Engine.ini.' }
            default { Warn 'Skipped. Exposure/fog may look wrong until the required cvars are present.'; $skipped = $true }
        }
    } else {
        WriteLines $iniDst $MinIni
        Ok 'Wrote new Engine.ini.'
    }
    if(-not $skipped){
        (Get-Item $iniDst).IsReadOnly = $true
        Ok 'Set Engine.ini read-only (stops the game overwriting it).'
    }

} finally {
    if(Test-Path $tmp){ Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ----- done ------------------------------------------------------------------
Step 'Done'
Ok 'Installation complete.'
Say ''
Say 'Launch the game and let time pass, or use the keybinds:' White
Say '  Alt+S / Alt+Shift+S  cycle weather    Alt+T  cycle time speed'
Say '  Alt+Q  headlight mode                 Alt+B / Alt+Shift+B  headlight brightness'
Say ''
