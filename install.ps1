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
# PINNED UE4SS build (since 3.9.0, unchanged for 4.0.0): nightly g1c1a1497
# (2026-08-08) repacked with the TXR signature + tuned settings, hosted as a
# release asset on this repo so the link can never be overwritten by a newer
# nightly. Every field hour since 3.9.0 is on this exact build. (A planned
# bump to zDEV a1e7f571 was dropped at release: hash checks showed the
# local install still runs g1c1a1497, so the newer build has NO verified
# field time; bump only after it truly runs clean locally.)
$UE4SSUrl = 'https://github.com/andizla/TXRWM/releases/download/v3.9.0/UE4SS-TXR-g1c1a1497.zip'

# GitHub release asset. Name the release zip 'TXR_Weather_V3.zip' so this resolves.
# Leave as '' to install from a local TXR_Weather_V3 folder next to this script
# (pre-release testing) - the repo/release don't exist yet as of writing.
$ModUrl   = 'https://github.com/andizla/TXRWM/releases/latest/download/TXR_Weather_V3.zip'

# Baked content paks (road/tunnel shadow flags + tunnel collision), hosted as
# their own release asset because the collision pak is ~291 MB and only needs
# re-baking when the GAME updates. PINNED to a release tag, not /latest, so a
# re-bake can be published without silently changing what older installs pull.
# Hosted on the v4.0.0 release. Leave as '' to skip the download step
# entirely.
$PaksUrl  = 'https://github.com/andizla/TXRWM/releases/download/v4.0.0/TXRWM_Paks.zip'

# Minimal required engine.ini (the only cvars the mod needs to function).
$MinIni = @(
    '[ConsoleVariables]',
    'r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange=1',
    'r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange=True',
    'r.fog=1',
    'r.Lumen.SampleFog=1',
    'r.NGX.DLSS.AutoExposure=0'
)

# Installer-OWNED cvars. Stripped from any chosen base profile and re-appended
# as one managed block, so the installer is the single source of truth for them
# on every profile. r.EyeAdaptation.MethodOverride stays in $ManagedKeys (never
# in a write set) so upgrades STRIP it from existing files: a leftover
# MethodOverride=3 breaks the 3.4+ exposure system.
$FogCvars    = @('r.fog=1', 'r.Lumen.SampleFog=1')
$ExpOnCvars  = @(
    'r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange=1',
    'r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange=True',
    'r.NGX.DLSS.AutoExposure=0'
)
$ExpOffCvars = @('r.NGX.DLSS.AutoExposure=1')
$ManagedKeys = @(
    'r.fog',
    'r.Lumen.SampleFog',
    'r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange',
    'r.NGX.DLSS.AutoExposure',
    'r.EyeAdaptation.MethodOverride'
)

# Build an Engine.ini from a base profile: drop the managed cvars out of the
# base, then append one managed block. An empty base yields the minimal profile.
function Compose-Ini($baseLines, $exposureOn){
    $out = New-Object System.Collections.Generic.List[string]
    foreach($l in $baseLines){
        $key = (($l -split '=', 2)[0]).Trim()
        if($ManagedKeys -contains $key){ continue }
        $out.Add($l)
    }
    $out.Add('')
    $out.Add('; === TXR Weather Mod - required cvars (managed by installer) ===')
    $out.Add('[ConsoleVariables]')
    foreach($c in $FogCvars){ $out.Add($c) }
    $expSet = if($exposureOn){ $ExpOnCvars } else { $ExpOffCvars }
    foreach($c in $expSet){ $out.Add($c) }
    return [string[]]$out
}

# Set a boolean inside a Config.<Section> = { ... } block in the installed
# config.lua. Used for the exposure choice and for the collision-pak fallback.
# Brace-depth aware: a nested table (e.g. a pattern list) above the key must
# not end the scan, and only the assignment itself is replaced, never a
# true/false inside a trailing comment.
function Set-ConfigBool($modDst, $sectionPattern, $keyPattern, $on){
    $cfg = Join-Path $modDst 'Scripts\config.lua'
    if(-not (Test-Path $cfg)){ return $false }
    $val = if($on){ 'true' } else { 'false' }
    $lines = @(Get-Content $cfg)
    $depth = 0
    for($i = 0; $i -lt $lines.Count; $i++){
        $code = $lines[$i] -replace '--.*$', ''
        if($depth -eq 0){
            if($lines[$i] -match $sectionPattern){
                $depth = ([regex]::Matches($code, '\{').Count) - ([regex]::Matches($code, '\}').Count)
                if($depth -le 0){ return $false }
            }
            continue
        }
        if($depth -eq 1 -and $lines[$i] -match $keyPattern){
            $lines[$i] = [regex]::new('(=\s*)(true|false)').Replace($lines[$i], ('${1}' + $val), 1)
            WriteLines $cfg $lines
            return $true
        }
        $depth += ([regex]::Matches($code, '\{').Count) - ([regex]::Matches($code, '\}').Count)
        if($depth -le 0){ break }
    }
    return $false
}

# Match Config.ModuleToggles.LightCycle to the chosen exposure mode. LightCycle
# is the sun-elevation exposure module; "no exposure" = module off = vanilla.
function Set-ExposureFlag($modDst, $on){
    return (Set-ConfigBool $modDst '^\s*Config\.ModuleToggles\s*=\s*\{' '^\s*LightCycle\s*=' $on)
}

# The runtime rain-collision pass can either rely on the baked collision pak
# (CtfWrite = false, the shipping default) or write the collision flags itself
# (CtfWrite = true). Without the pak the runtime MUST do it, or rain falls
# through tunnel roofs, so the installer matches this to what actually got
# installed.
function Set-CtfWrite($modDst, $on){
    return (Set-ConfigBool $modDst '^\s*Config\.RainCollision\s*=\s*\{' '^\s*CtfWrite\s*=' $on)
}

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
    $existing  = @(); if(Test-Path $path){ $existing = @(Get-Content $path) }
    $out = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach($l in $existing){
        if($l -eq $marker){ $inBlock = $true; continue }
        if($l -eq $endMarker){ $inBlock = $false; continue }
        if(-not $inBlock){ $out.Add($l) }
    }
    $cvars = $minLines | Where-Object { $_ -ne '' -and ($_ -notmatch '^\s*\[') }
    # Only repeat the section header when the file does not already END inside
    # [ConsoleVariables]; a duplicate header is harmless ini-wise (last wins)
    # but it reads as a mistake and confused a hand-edit once (2026-08-04).
    $lastSection = $out | Where-Object { $_ -match '^\s*\[' } | Select-Object -Last 1
    $needHeader = (-not $lastSection) -or ($lastSection.Trim() -ne '[ConsoleVariables]')
    $block = @('', $marker)
    if($needHeader){ $block += '[ConsoleVariables]' }
    $block = $block + $cvars + @($endMarker)
    WriteLines $path ($out + $block)
}

# ----- start -----------------------------------------------------------------
Say "================================================" White
Say "  TXR Weather Mod V3 - Installer" White
Say "================================================" White

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

# temp workspace for downloads
$tmp = Join-Path $env:TEMP ('txrwm_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {

    # 2) UE4SS ----------------------------------------------------------------
    Step 'UE4SS'
    $haveUE4SS = (Test-Path (Join-Path $win64 'dwmapi.dll')) -and (Test-Path $ue4ss)
    $installUE4SS = $true
    if($haveUE4SS){
        Warn 'UE4SS is already installed here.'
        Say  '    The mod ships a pinned, field-proven UE4SS build (the same one'
        Say  '    3.9.0 and 3.10.0 used). Updating is recommended if your UE4SS'
        Say  '    is older than that.'
        $installUE4SS = AskYesNo 'Update UE4SS now? (your existing Mods are kept)' $true
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
        # Stale AOB caches belong to the previous DLL; UE4SS would invalidate
        # them itself, but a clean slate avoids one class of upgrade surprise.
        Remove-Item (Join-Path $ue4ss 'cache') -Recurse -Force -ErrorAction SilentlyContinue
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
    # Files carried across an update: persisted runtime state and the collected
    # tuning datapoints. config.lua intentionally resets (release defaults move).
    # (Restored 2026-08-26: the 3.9.0 installer rework dropped this block, so
    # every update since silently deleted the user's saved state and feedback log.)
    $keepFiles = @('last_state.txt','last_state.txt.bak','headlight_state.txt','Logs\tuning_feedback.log')
    $keepDir = $null
    if(Test-Path $modDst){
        if(AskYesNo 'Mod already installed. Overwrite (update) it?'){
            foreach($rel in $keepFiles){
                $src = Join-Path $modDst $rel
                if(Test-Path $src){
                    if(-not $keepDir){
                        $keepDir = Join-Path $tmp 'keep'
                        New-Item -ItemType Directory -Force -Path $keepDir | Out-Null
                    }
                    $dst = Join-Path $keepDir $rel
                    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                    Copy-Item $src $dst -Force
                }
            }
            Remove-Item $modDst -Recurse -Force
        }
        else { Warn 'Keeping existing mod files.' }
    }
    if(-not (Test-Path $modDst)){
        $rc = @($modRoot, $modDst, '/E','/NFL','/NDL','/NJH','/NJS','/NP','/XD','Logs','.backup','Paks','/XF','*.bak')
        & robocopy @rc | Out-Null
        if($LASTEXITCODE -ge 8){ throw "robocopy failed copying the mod (code $LASTEXITCODE)" }
        Ok "Installed mod to $modDst"
        if($keepDir){
            foreach($rel in $keepFiles){
                $src = Join-Path $keepDir $rel
                if(Test-Path $src){
                    $dst = Join-Path $modDst $rel
                    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                    Copy-Item $src $dst -Force
                }
            }
            Ok 'Restored your saved state (time of day, weather, headlights) and tuning_feedback.log.'
        }
    }

    # 3a) Content paks (4.0.0+) ----------------------------------------------
    # The baked content patches (two-sided road/tunnel shadow flags, tunnel
    # collision) ship as their OWN release asset, not inside the mod zip: the
    # collision pak alone is ~291 MB and only needs re-baking when the GAME
    # updates, while the mod's Lua ships far more often. A local <mod>\Paks
    # folder still wins when present (pre-release testing).
    #
    # If the paks are not installed, the runtime pass must write the collision
    # flags itself or rain falls through tunnel roofs, so CtfWrite is matched
    # to what actually landed.
    Step 'Content paks (baked shadow + rain collision)'
    $gameRoot = Split-Path (Split-Path $win64 -Parent) -Parent   # ...\TokyoXtremeRacer\TokyoXtremeRacer
    $paksDst  = Join-Path $gameRoot 'Content\Paks'
    $pakSrc   = Join-Path $modRoot 'Paks'
    $paksIn   = $false

    if(-not (Test-Path $pakSrc)){
        $pakSrc = $null
        Say '    These make covered roads correct from the first frame of a course'
        Say '    (shadows and rain occlusion baked into the map data) instead of the'
        Say '    mod repairing them a few seconds in. Large one-time download; they'
        Say '    only change when the GAME updates, not on every mod release.'
        if($PaksUrl -and (AskYesNo '    Download the content paks now? (about 100 MB download, ~300 MB on disk)' $true)){
            try {
                $pext = Join-Path $tmp 'paks'
                New-Item -ItemType Directory -Force -Path $pext | Out-Null
                $pzip = Join-Path $tmp 'paks.zip'
                Ok 'Downloading content paks (this one is big)...'
                Download-Zip $PaksUrl $pzip
                Ok 'Extracting...'
                Expand-Archive -Path $pzip -DestinationPath $pext -Force
                $pakSrc = $pext
            } catch {
                Warn "Content pak download failed: $($_.Exception.Message)"
                $pakSrc = $null
            }
        }
    }

    # Superseded/retired names from earlier TXRWM pak generations: cleaned
    # whenever they are present, NOT only when new paks land (the retired
    # building-shadow bake must go even if the user declines the download).
    if(Test-Path $paksDst){
        foreach($old in @('zzz_TXRWM_ColPilot_P','zzz_TXRWM_ColTest_c1_P','zzz_TXRWM_ColTest_wni1_P','zzz_TXRWM_ColTest_wnj1_P','zzz_TXRWM_ColTest_wnj2_P','TXRWM_BuildingShadowsC1_P','TXRWM_BuildingShadows_P')){
            Remove-Item (Join-Path $paksDst "$old.*") -Force -ErrorAction SilentlyContinue
        }
    }
    if($pakSrc -and (Test-Path $paksDst)){
        $trioFiles = @(Get-ChildItem $pakSrc -File -Include '*.pak','*.ucas','*.utoc' -Recurse)
        if($trioFiles.Count -gt 0){
            foreach($f in $trioFiles){ Copy-Item $f.FullName $paksDst -Force }
            $names = (($trioFiles | Where-Object { $_.Extension -eq '.pak' } | ForEach-Object { $_.BaseName }) | Sort-Object) -join ', '
            Ok "Installed content paks: $names"
            $paksIn = $true
        } else {
            Warn 'No .pak/.ucas/.utoc files found in the pak source.'
        }
    } elseif($pakSrc) {
        Warn "Content\Paks not found at $paksDst - skipped content paks."
    }

    if($paksIn){
        [void](Set-CtfWrite $modDst $false)
        Ok 'Rain occlusion will use the baked collision data.'
    } else {
        if(Set-CtfWrite $modDst $true){
            Warn 'No content paks installed: the mod will do the collision work at'
            Warn 'runtime instead (config CtfWrite = true). Everything still works;'
            Warn 'covered sections just settle a few seconds into each course.'
        } else {
            Warn 'No content paks installed AND the config could not be updated.'
            Warn "Set Config.RainCollision.CtfWrite = true by hand in $modDst\Scripts\config.lua"
            Warn 'or rain will fall through tunnel roofs.'
        }
    }

    # mods.txt (idempotent)
    $modsTxt = Join-Path $modsDir 'mods.txt'
    $lines = @()
    if(Test-Path $modsTxt){ $lines = @(Get-Content $modsTxt) }
    if($lines -match "^\s*$ModName\s*:"){
        Ok 'mods.txt already lists the mod.'
    } else {
        $lines += "$ModName : 1"
        WriteLines $modsTxt $lines
        Ok "Added '$ModName : 1' to mods.txt"
    }

    # 3b) Look options ---------------------------------------------------------
    Step 'Look options'
    $cfgLua = Join-Path $modDst 'Scripts\config.lua'
    if(Test-Path $cfgLua){
        if(AskYesNo 'Dark garage look? (low-key show-floor lighting with headlights on; tuned on an HDR display)' $true){
            Ok 'Dark garage look enabled (default).'
        } else {
            $t = [IO.File]::ReadAllText($cfgLua)
            $t = $t -replace '(GarageDark\s*=\s*\{[^\}]*?Enabled\s*=\s*)true', '${1}false'
            $t = $t -replace '(GarageAlwaysOn\s*=\s*)true', '${1}false'
            [IO.File]::WriteAllText($cfgLua, $t, (New-Object Text.UTF8Encoding($false)))
            Ok 'Dark garage disabled (stock garage look).'
        }
    }

    # 4) Conflicting older mods (standalone VEAO, the old day/night mod) -----
    foreach($veao in @('VEAOV213B','VEAO','TXR_DayNightCycle')){
        $vp = Join-Path $modsDir $veao
        if(Test-Path $vp){
            Warn "Found old standalone '$veao' - it drives the same sky/exposure systems and fights this mod."
            if(AskYesNo "Disable '$veao' in mods.txt?"){
                $ml = @(Get-Content $modsTxt)
                if($ml -match "^\s*$veao\s*:"){ $ml = $ml -replace "^\s*$veao\s*:.*", "$veao : 0" }
                else { $ml += "$veao : 0" }
                WriteLines $modsTxt $ml
                Ok "Disabled '$veao'."
            }
        }
    }

    # 5) engine.ini (graphics profile selector) ------------------------------
    # Restored 2026-08-26: the 3.9.0 rework left "Engine.ini profile port" as an
    # open checklist item, so 3.9/3.10 shipped with no profile selector at all
    # even though the base profiles still ship in the mod folder. Merge stays as
    # an option for users running their own tuned Engine.ini.
    Step 'Engine.ini - graphics profile'
    Say '    Engine.ini supplies the cvars the mod relies on (exposure + fog) and'
    Say '    sets the graphics profile. Any existing file is backed up first.'
    Say ''
    Say '      1) Photomode           highest fidelity, resource heavy   [recommended]' Green
    Say '      2) Optimizations only  lighter, good for midrange / non-DLSS rigs' Green
    Say '      3) Minimal             only the cvars the mod needs'
    Say '      4) Merge               keep my Engine.ini, just add the required cvars'
    Say '      5) Skip                leave my Engine.ini completely untouched'
    Say ''
    $pick = (Read-Host '    Choice [1-5, Enter = 1]').Trim()
    if($pick -eq ''){ $pick = '1' }

    $engDir = Join-Path $modDst 'engines'
    if(-not (Test-Path $engDir)){ $engDir = Join-Path $modRoot 'engines' }
    $base = $null; $label = ''; $mode = 'compose'
    switch($pick){
        '1' { $base = Join-Path $engDir 'photomode_engine.ini';         $label = 'Photomode' }
        '2' { $base = Join-Path $engDir 'optimization_only_engine.ini'; $label = 'Optimizations only' }
        '3' { $base = $null;                                            $label = 'Minimal' }
        '4' { $mode = 'merge' }
        default { $mode = 'skip' }
    }

    # The mod's dynamic day/night exposure is the sun-driven look; declining it
    # leaves vanilla brightness and switches the LightCycle module off to match.
    $exposureOn = $true
    if($mode -ne 'skip'){
        $exposureOn = AskYesNo '    Use the mod dynamic day/night exposure? (no = vanilla brightness)' $true
    }

    $cfgDir = Join-Path $env:LOCALAPPDATA 'TokyoXtremeRacer\Saved\Config\Windows'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $iniDst = Join-Path $cfgDir 'Engine.ini'

    if($mode -eq 'skip'){
        Warn 'Skipped. Exposure and fog may look wrong until the required cvars are present.'
    } else {
        if(Test-Path $iniDst){
            $f = Get-Item $iniDst
            if($f.IsReadOnly){ $f.IsReadOnly = $false }
            $bak = "$iniDst.bak." + (Get-Date -Format 'yyyyMMdd_HHmmss')
            Copy-Item $iniDst $bak
            Ok "Backed up existing Engine.ini -> $(Split-Path $bak -Leaf)"
        }
        if($mode -eq 'merge'){
            $expSet = if($exposureOn){ $ExpOnCvars } else { $ExpOffCvars }
            Merge-Cvars $iniDst (@('[ConsoleVariables]') + $FogCvars + $expSet)
            Ok 'Merged the required cvars at the end of your Engine.ini.'
        } else {
            $baseLines = @()
            if($base){
                if(Test-Path $base){ $baseLines = @(Get-Content $base) }
                else { Warn "Base profile not found ($([IO.Path]::GetFileName($base))) - using Minimal instead."; $label = 'Minimal (fallback)' }
            }
            WriteLines $iniDst (Compose-Ini $baseLines $exposureOn)
            $expLabel = if($exposureOn){ 'with dynamic exposure' } else { 'vanilla brightness' }
            Ok "Installed Engine.ini profile: $label, $expLabel."
        }
        (Get-Item $iniDst).IsReadOnly = $true
        Ok 'Set Engine.ini read-only (stops the game overwriting it).'
        if(-not (Set-ExposureFlag $modDst $exposureOn)){
            Warn 'Could not update Config.ModuleToggles.LightCycle to match the'
            Warn 'exposure choice - set it by hand in Scripts\config.lua if needed.'
        }
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
Say '  Alt+Q  headlight toggle               Alt+B / Alt+Shift+B  brightness'
Say '  Alt+G  dark look (garage/photo)       Alt+E  exposure trim'
Say ''
