# =============================================================================
# TXR Weather Mod V3 - Installer
# -----------------------------------------------------------------------------
# Self-contained: ships as just install.bat + install.ps1.
#   - UE4SS  : downloaded at runtime (CookiePLMonster TXR25 build)
#   - Mod    : downloaded at runtime from $ModUrl (GitHub release zip)
#   - engine.ini : the managed cvars are embedded below ($FogCvars/$ExpCvars)
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

# Installer-OWNED cvars. Stripped from any chosen base profile and re-appended
# as one managed block, so the installer is the single source of truth for them
# on every profile. r.EyeAdaptation.MethodOverride stays in $ManagedKeys (never
# in a write set) so upgrades STRIP it from existing files: a leftover
# MethodOverride=3 breaks the 3.4+ exposure system.
# The exposure cvars are UNCONDITIONAL since 2026-09-01 (user call): the mod
# exists because the vanilla auto-exposure is broken, so an install-time
# "no exposure" question only collected blind "no" answers - a look with zero
# field hours that also silently killed the dark garage and the brightness
# keybinds. Opting out is config-side now:
# Config.ModuleToggles.LightCycle = false in Scripts\config.lua.
$FogCvars = @('r.fog=1', 'r.Lumen.SampleFog=1')
$ExpCvars = @(
    'r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange=1',
    'r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange=True',
    'r.NGX.DLSS.AutoExposure=0'
)
$ManagedKeys = @(
    'r.fog',
    'r.Lumen.SampleFog',
    'r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange',
    'r.NGX.DLSS.AutoExposure',
    'r.EyeAdaptation.MethodOverride'
)
$ComposeMarker = '; === TXR Weather Mod - required cvars (managed by installer) ==='

# Build an Engine.ini from a base profile: drop the managed cvars out of the
# base, then append one managed block. An empty base yields the minimal profile.
function Compose-Ini($baseLines){
    $out = New-Object System.Collections.Generic.List[string]
    foreach($l in $baseLines){
        $key = (($l -split '=', 2)[0]).Trim()
        if($ManagedKeys -contains $key){ continue }
        $out.Add($l)
    }
    $out.Add('')
    $out.Add($ComposeMarker)
    $out.Add('[ConsoleVariables]')
    foreach($c in $FogCvars){ $out.Add($c) }
    foreach($c in $ExpCvars){ $out.Add($c) }
    return [string[]]$out
}

# Set a boolean inside a Config.<Section> = { ... } block in the installed
# config.lua. Used for the collision-pak fallback (CtfWrite).
# Brace-depth aware: a nested table (e.g. a pattern list) above the key must
# not end the scan, and only the assignment itself is replaced, never a
# true/false inside a trailing comment.
function Set-ConfigBool($modDst, $sectionPattern, $keyPattern, $on){
    $cfg = Join-Path $modDst 'Scripts\config.lua'
    if(-not (Test-Path -LiteralPath $cfg)){ return $false }
    $val = if($on){ 'true' } else { 'false' }
    # ReadAllLines: the file is UTF-8 and is written back as UTF-8 below;
    # Get-Content on 5.1 would read it in the ANSI codepage
    $lines = @([IO.File]::ReadAllLines($cfg))
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

# ----- game detection --------------------------------------------------------
# One thing is invariant across every install layout: the UE project interior
# <install>\TokyoXtremeRacer\Binaries\Win64\TokyoXtremeRacer-Win64-Shipping.exe.
# Outer folder names prove nothing (2026-07-16 field case: a non-Steam copy at
# C:\Games\Tokyo Xtreme Racer\), so the probes below stat that fixed suffix and
# never match on names. Detection runs under $ErrorActionPreference = 'Stop',
# so every probe is fault-isolated: a denied registry key or a dead junction
# must never kill the installer.
# Paths here are -LiteralPath: a folder name with [ ] (a legal Windows name)
# is a wildcard to Test-Path/Get-ChildItem and would make the game undetectable
# AND unpasteable, and Resolve-Win64 returns a full normalized path so a
# forward-slash or relative entry cannot leak into robocopy or the Steam check.
$ExeName = 'TokyoXtremeRacer-Win64-Shipping.exe'

# Normalize any lead (a Win64 dir, the game root, the TokyoXtremeRacer project
# dir, or a path to either exe) to the Binaries\Win64 folder, else $null.
function Resolve-Win64($raw){
    if(-not $raw){ return $null }
    $p = ([string]$raw).Trim().Trim('"').TrimEnd('\','/')
    if(-not $p){ return $null }
    try { if(Test-Path -LiteralPath $p -PathType Leaf){ $p = Split-Path $p -Parent } } catch { return $null }
    try { if(-not (Test-Path -LiteralPath $p)){ return $null } } catch { return $null }
    foreach($rel in @('', 'Binaries\Win64', 'TokyoXtremeRacer\Binaries\Win64')){
        $d = if($rel){ Join-Path $p $rel } else { $p }
        if(Test-Path -LiteralPath (Join-Path $d $ExeName)){ try { return [IO.Path]::GetFullPath($d) } catch { return $d } }
    }
    try {
        $hit = Get-ChildItem -LiteralPath $p -Recurse -Depth 4 -Filter $ExeName -ErrorAction SilentlyContinue | Select-Object -First 1
        if($hit){ return $hit.DirectoryName }
    } catch {}
    return $null
}

# Every detection source, cheap first. Returns validated {Path, Source} rows
# (Path = the Win64 dir), deduped case-insensitively.
function Find-GameInstalls {
    $list = New-Object System.Collections.ArrayList
    $seen = @{}
    function AddHit($dir, $src){
        if(-not $dir){ return }
        try { $dir = [IO.Path]::GetFullPath($dir) } catch { return }
        try { if(-not (Test-Path -LiteralPath (Join-Path $dir $ExeName))){ return } } catch { return }
        $k = $dir.ToLowerInvariant()
        if($seen.ContainsKey($k)){ return }
        $seen[$k] = $true
        [void]$list.Add([pscustomobject]@{ Path = $dir; Source = $src })
    }
    # An exe path lead: its parent is either the Win64 dir (shipping exe) or
    # the install root (the TokyoXtremeRacer.exe launcher).
    function AddExeLead($exePath, $src){
        if(-not $exePath){ return }
        $d = $null
        try { $d = Split-Path $exePath -Parent } catch { return }
        foreach($rel in @('', 'TokyoXtremeRacer\Binaries\Win64', 'Binaries\Win64')){
            $dd = if($rel){ Join-Path $d $rel } else { $d }
            AddHit $dd $src
        }
    }

    # a) The installer's own location. Users drop install.bat next to the exe,
    #    into the game root, or beside the game folder - walk up 6 levels,
    #    probing each level and its immediate children (GrabLogs' walk-up,
    #    minus its blind recursion).
    $probe = $Root
    for($i = 0; $i -lt 6 -and $probe; $i++){
        foreach($rel in @('', 'Binaries\Win64', 'TokyoXtremeRacer\Binaries\Win64')){
            $d = if($rel){ Join-Path $probe $rel } else { $probe }
            AddHit $d 'next to this installer'
        }
        try {
            foreach($c in @(Get-ChildItem -LiteralPath $probe -Directory -ErrorAction SilentlyContinue)){
                AddHit (Join-Path $c.FullName 'TokyoXtremeRacer\Binaries\Win64') 'next to this installer'
            }
        } catch {}
        $probe = Split-Path $probe -Parent
    }

    # b) The game is running right now.
    try {
        foreach($proc in @(Get-Process 'TokyoXtremeRacer-Win64-Shipping' -ErrorAction SilentlyContinue)){
            try { AddExeLead $proc.Path 'running right now' } catch {}
        }
    } catch {}

    # c) Steam: registry -> libraryfolders.vdf -> the canonical folder
    #    (recursive, as always), then every OTHER library game folder via the
    #    fixed suffix - one stat per game catches a renamed install dir.
    $libs = @()
    $steam = $null
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
    if(-not $steam){ try { $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch {} }
    if($steam){
        $steam = $steam -replace '/','\'
        $libs += $steam
        try {
            $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
            if(Test-Path -LiteralPath $vdf){
                foreach($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s*"([^"]+)"')){
                    $libs += ($m.Groups[1].Value -replace '\\\\','\')
                }
            }
        } catch {}
    }
    foreach($lib in @($libs | Select-Object -Unique)){
        try {
            $common = Join-Path $lib 'steamapps\common'
            $canon  = Join-Path $common 'TokyoXtremeRacer'
            if(Test-Path -LiteralPath $canon){
                $exe = Get-ChildItem -LiteralPath $canon -Recurse -Filter $ExeName -ErrorAction SilentlyContinue | Select-Object -First 1
                if($exe){ AddHit $exe.DirectoryName 'Steam' }
            }
            foreach($c in @(Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue)){
                AddHit (Join-Path $c.FullName 'TokyoXtremeRacer\Binaries\Win64') 'Steam'
            }
        } catch {}
    }

    # d) Windows kept the full exe path if the game ever ran here, wherever it
    #    lives: Game DVR config, the Compatibility Assistant store, the shell's
    #    MuiCache. All HKCU, no admin. This is the main non-Steam catch.
    try {
        foreach($k in @(Get-ChildItem 'HKCU:\System\GameConfigStore\Children' -ErrorAction SilentlyContinue)){
            try {
                $v = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).MatchedExeFullPath
                if($v -and $v -match 'TokyoXtremeRacer[^\\]*\.exe$'){ AddExeLead $v 'ran on this PC before' }
            } catch {}
        }
    } catch {}
    foreach($reg in @('HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store',
                      'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache')){
        try {
            $key = Get-Item -LiteralPath $reg -ErrorAction SilentlyContinue
            if($key){
                foreach($name in @($key.GetValueNames())){
                    if($name -match '^(?<exe>.+?TokyoXtremeRacer[^\\]*\.exe)(\.|$)'){
                        AddExeLead $Matches['exe'] 'ran on this PC before'
                    }
                }
            }
        } catch {}
    }

    # e) Installed-app entries (a non-Steam installer that registered itself).
    foreach($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                       'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall')){
        try {
            foreach($k in @(Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue)){
                try {
                    $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                    if($p -and $p.DisplayName -match 'Tokyo\s*Xtreme\s*Racer' -and $p.InstallLocation){
                        AddHit (Resolve-Win64 $p.InstallLocation) 'installed app list'
                    }
                } catch {}
            }
        } catch {}
    }

    # f) Desktop / Start Menu shortcuts pointing at either exe.
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnkDirs = @()
        foreach($sf in @('Desktop','CommonDesktopDirectory','StartMenu','CommonStartMenu')){
            try { $lnkDirs += [Environment]::GetFolderPath($sf) } catch {}
        }
        foreach($dir in @($lnkDirs | Where-Object { $_ } | Select-Object -Unique)){
            foreach($lnk in @(Get-ChildItem -LiteralPath $dir -Recurse -Depth 2 -Filter '*.lnk' -ErrorAction SilentlyContinue)){
                try {
                    $t = $wsh.CreateShortcut($lnk.FullName).TargetPath
                    if($t -match 'TokyoXtremeRacer[^\\]*\.exe$'){ AddExeLead $t 'shortcut' }
                } catch {}
            }
        }
    } catch {}

    # g) Common game folders on every ready drive: each root and one level of
    #    children, fixed-suffix stats only. The full recursive walk is the
    #    consent-gated deep scan, not this.
    try {
        foreach($dr in [IO.DriveInfo]::GetDrives()){
            $ok = $false
            try { $ok = $dr.IsReady -and (@('Fixed','Removable') -contains "$($dr.DriveType)") } catch {}
            if(-not $ok){ continue }
            $r = $dr.RootDirectory.FullName
            foreach($root in @($r, (Join-Path $r 'Games'), (Join-Path $r 'Game'),
                               (Join-Path $r 'SteamLibrary\steamapps\common'),
                               (Join-Path $r 'Steam\steamapps\common'),
                               (Join-Path $r 'Program Files\Steam\steamapps\common'),
                               (Join-Path $r 'Program Files (x86)\Steam\steamapps\common'))){
                try {
                    if(-not (Test-Path -LiteralPath $root)){ continue }
                    AddHit (Join-Path $root 'TokyoXtremeRacer\Binaries\Win64') 'found on disk'
                    foreach($c in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Select-Object -First 200)){
                        AddHit (Join-Path $c.FullName 'TokyoXtremeRacer\Binaries\Win64') 'found on disk'
                    }
                } catch {}
            }
        }
    } catch {}

    return @($list)
}

# Consent-gated deep scan: recursive exe search over every ready drive minus
# system folders, plus the user's Downloads/Desktop/Documents. Slow by design;
# offered only when everything in Find-GameInstalls missed.
function Find-DeepInstalls {
    $list = New-Object System.Collections.ArrayList
    $seen = @{}
    $skip = @('windows','programdata','perflogs','$recycle.bin','system volume information',
              'program files','program files (x86)','users')
    $roots = @()
    try {
        foreach($dr in [IO.DriveInfo]::GetDrives()){
            $ok = $false
            try { $ok = $dr.IsReady -and (@('Fixed','Removable') -contains "$($dr.DriveType)") } catch {}
            if(-not $ok){ continue }
            try {
                foreach($c in @(Get-ChildItem -LiteralPath $dr.RootDirectory.FullName -Directory -ErrorAction SilentlyContinue)){
                    if($skip -contains $c.Name.ToLowerInvariant()){ continue }
                    $roots += $c.FullName
                }
            } catch {}
        }
    } catch {}
    foreach($u in @('Downloads','Desktop','Documents')){
        try { $roots += (Join-Path $env:USERPROFILE $u) } catch {}
    }
    foreach($root in @($roots | Select-Object -Unique)){
        try {
            if(-not (Test-Path -LiteralPath $root)){ continue }
            foreach($hit in @(Get-ChildItem -LiteralPath $root -Recurse -Depth 5 -Filter $ExeName -ErrorAction SilentlyContinue)){
                $d = $hit.DirectoryName
                $k = $d.ToLowerInvariant()
                if(-not $seen.ContainsKey($k)){
                    $seen[$k] = $true
                    [void]$list.Add([pscustomobject]@{ Path = $d; Source = 'drive scan' })
                }
            }
        } catch {}
    }
    return @($list)
}

function Download-Zip($url, $outFile){
    Invoke-WebRequest -Uri $url -OutFile $outFile
}

# Find the actual mod root (the folder containing Scripts\main.lua) inside an
# extracted tree, regardless of how the zip is packed.
function Find-ModRoot($base){
    if(Test-Path -LiteralPath (Join-Path $base 'Scripts\main.lua')){ return $base }
    $cand = Get-ChildItem -LiteralPath $base -Recurse -Filter 'main.lua' -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq 'Scripts' } | Select-Object -First 1
    if($cand){ return (Split-Path $cand.Directory.FullName -Parent) }
    return $null
}

# Merge our required cvars as a managed block at the END of an existing ini so
# they apply last and win over any conflicting earlier values. Idempotent.
function Merge-Cvars($path, $cvarLines){
    $marker    = '; === TXR Weather Mod (required cvars) - managed by installer ==='
    $endMarker = '; === end TXR Weather Mod ==='
    $existing  = @(); if(Test-Path -LiteralPath $path){ $existing = @(Get-Content -LiteralPath $path) }
    $out = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach($l in $existing){
        if($l -eq $marker){ $inBlock = $true; continue }
        if($l -eq $endMarker){ $inBlock = $false; continue }
        if($inBlock){ continue }
        # Outside the block, a stale managed key (an old MethodOverride) or the
        # Compose-mode marker from an earlier profile install goes too, so an
        # upgrade through Merge strips them the way Compose does
        $key = (($l -split '=', 2)[0]).Trim()
        if($ManagedKeys -contains $key){ continue }
        if($l -eq $ComposeMarker){ continue }
        $out.Add($l)
    }
    $cvars = $cvarLines | Where-Object { $_ -ne '' -and ($_ -notmatch '^\s*\[') }
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
$found = @(Find-GameInstalls | Select-Object -First 9)
if($found.Count -eq 0){
    Warn 'Not found automatically (Steam, run history, shortcuts, common folders).'
    if(AskYesNo 'Scan your drives for it now? (thorough, can take a few minutes)' $true){
        Say '    Scanning...'
        $found = @(Find-DeepInstalls | Select-Object -First 9)
    }
}
if($found.Count -eq 1){
    Ok "Detected: $($found[0].Path)  [$($found[0].Source)]"
    if(AskYesNo 'Install to this location?'){ $win64 = $found[0].Path }
} elseif($found.Count -gt 1){
    Say '    Found more than one possible install:' White
    for($i = 0; $i -lt $found.Count; $i++){
        Say ("      {0}) {1}  [{2}]" -f ($i + 1), $found[$i].Path, $found[$i].Source) Green
    }
    $pick = (Read-Host "    Choice [1-$($found.Count), Enter = 1, m = type a path]").Trim()
    if($pick -eq ''){ $pick = '1' }
    $idx = 0
    if([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $found.Count){
        $win64 = $found[$idx - 1].Path
    }
}
while(-not $win64){
    Warn 'Paste a path to the game. Any of these forms work:'
    Warn '  - the install folder (the one holding TokyoXtremeRacer.exe)'
    Warn '  - its TokyoXtremeRacer subfolder, or ...\Binaries\Win64'
    Warn "  - the full path to $ExeName"
    $win64 = Resolve-Win64 (Read-Host 'Path')
    if(-not $win64){ Warn "Could not find $ExeName under that path. Try again." }
}
Ok "Game: $win64"
try {
    if(@(Get-Process 'TokyoXtremeRacer-Win64-Shipping' -ErrorAction SilentlyContinue).Count -gt 0){
        Warn 'The game is RUNNING. Close it before continuing or file copies will fail.'
    }
} catch {}
if($win64 -notmatch '\\steamapps\\'){
    # Non-Steam copies are supported, and build skew there is real (3.6.0 field
    # case: exe 171,212,800 bytes vs Steam 171,489,280 = rain particles dead).
    Warn 'Non-Steam layout detected. The mod targets the current Steam build; if'
    Warn 'weather visuals misbehave (e.g. no rain), suspect a build mismatch first.'
}
$ue4ss   = Join-Path $win64 'ue4ss'
$modsDir = Join-Path $ue4ss 'Mods'

# temp workspace for downloads
$tmp = Join-Path $env:TEMP ('txrwm_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {

    # 2) UE4SS ----------------------------------------------------------------
    Step 'UE4SS'
    $haveUE4SS = (Test-Path -LiteralPath (Join-Path $win64 'dwmapi.dll')) -and (Test-Path -LiteralPath $ue4ss)
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
        if(-not (Test-Path -LiteralPath (Join-Path $srcDir 'dwmapi.dll'))){
            $sub = Get-ChildItem -LiteralPath $ext -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'dwmapi.dll') } | Select-Object -First 1
            if($sub){ $srcDir = $sub.FullName }
        }
        if(-not (Test-Path -LiteralPath (Join-Path $srcDir 'dwmapi.dll'))){ throw 'Downloaded UE4SS archive did not contain dwmapi.dll (unexpected layout).' }
        $rc = @($srcDir, $win64, '/E','/NFL','/NDL','/NJH','/NJS','/NP')
        # Never clobber an existing Mods folder: the UE4SS zip carries a stock
        # Mods\mods.txt, so the guard keys on the folder itself rather than on
        # dwmapi.dll (a renamed proxy DLL used to switch the guard off)
        if(Test-Path -LiteralPath (Join-Path $ue4ss 'Mods')){ $rc += @('/XD','Mods') }
        & robocopy @rc | Out-Null
        if($LASTEXITCODE -ge 8){ throw "robocopy failed copying UE4SS (code $LASTEXITCODE)" }
        # Stale AOB caches belong to the previous DLL; UE4SS would invalidate
        # them itself, but a clean slate avoids one class of upgrade surprise.
        Remove-Item -LiteralPath (Join-Path $ue4ss 'cache') -Recurse -Force -ErrorAction SilentlyContinue
        Ok 'UE4SS installed.'
    }
    New-Item -ItemType Directory -Force -Path $modsDir | Out-Null

    # 3) Mod files (download, or local fallback) ------------------------------
    Step 'Mod files'
    $modRoot = $null
    $localMod = Join-Path $Root $ModName
    $localHasMod = Test-Path -LiteralPath (Join-Path $localMod 'Scripts\main.lua')
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
    if(Test-Path -LiteralPath $modDst){
        if(AskYesNo 'Mod already installed. Overwrite (update) it?'){
            foreach($rel in $keepFiles){
                $src = Join-Path $modDst $rel
                if(Test-Path -LiteralPath $src){
                    if(-not $keepDir){
                        $keepDir = Join-Path $tmp 'keep'
                        New-Item -ItemType Directory -Force -Path $keepDir | Out-Null
                    }
                    $dst = Join-Path $keepDir $rel
                    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                    Copy-Item -LiteralPath $src -Destination $dst -Force
                }
            }
            Remove-Item -LiteralPath $modDst -Recurse -Force
        }
        else { Warn 'Keeping existing mod files.' }
    }
    if(-not (Test-Path -LiteralPath $modDst)){
        $rc = @($modRoot, $modDst, '/E','/NFL','/NDL','/NJH','/NJS','/NP','/XD','Logs','.backup','Paks','/XF','*.bak')
        & robocopy @rc | Out-Null
        if($LASTEXITCODE -ge 8){ throw "robocopy failed copying the mod (code $LASTEXITCODE)" }
        Ok "Installed mod to $modDst"
        if($keepDir){
            foreach($rel in $keepFiles){
                $src = Join-Path $keepDir $rel
                if(Test-Path -LiteralPath $src){
                    $dst = Join-Path $modDst $rel
                    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                    Copy-Item -LiteralPath $src -Destination $dst -Force
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

    if(-not (Test-Path -LiteralPath $pakSrc)){
        $pakSrc = $null
        Say '    These make covered roads correctly shaded from the first frame of a'
        Say '    course (shadow casting baked into the map data) instead of the mod'
        Say '    repairing them a few seconds in. Rain occlusion runs in the mod'
        Say '    itself either way. Large one-time download; they only change when'
        Say '    the GAME updates, not on every mod release.'
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
    if(Test-Path -LiteralPath $paksDst){
        foreach($old in @('zzz_TXRWM_ColPilot_P','zzz_TXRWM_ColTest_c1_P','zzz_TXRWM_ColTest_wni1_P','zzz_TXRWM_ColTest_wnj1_P','zzz_TXRWM_ColTest_wnj2_P','TXRWM_BuildingShadowsC1_P','TXRWM_BuildingShadows_P')){
            Get-ChildItem -LiteralPath $paksDst -Filter "$old.*" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    if($pakSrc -and (Test-Path -LiteralPath $paksDst)){
        $trioFiles = @(Get-ChildItem -LiteralPath $pakSrc -File -Include '*.pak','*.ucas','*.utoc' -Recurse)
        if($trioFiles.Count -gt 0){
            foreach($f in $trioFiles){ Copy-Item -LiteralPath $f.FullName -Destination $paksDst -Force }
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
    if(Test-Path -LiteralPath $modsTxt){ $lines = @(Get-Content -LiteralPath $modsTxt) }
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
    if(Test-Path -LiteralPath $cfgLua){
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
        if(Test-Path -LiteralPath $vp){
            Warn "Found old standalone '$veao' - it drives the same sky/exposure systems and fights this mod."
            if(AskYesNo "Disable '$veao' in mods.txt?"){
                $ml = @(Get-Content -LiteralPath $modsTxt)
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
    $pick = ''
    while($pick -notmatch '^[1-5]$'){
        $pick = (Read-Host '    Choice [1-5, Enter = 1]').Trim()
        if($pick -eq ''){ $pick = '1' }
        if($pick -notmatch '^[1-5]$'){ Warn 'Please type a number from 1 to 5.' }
    }

    $engDir = Join-Path $modDst 'engines'
    if(-not (Test-Path -LiteralPath $engDir)){ $engDir = Join-Path $modRoot 'engines' }
    $base = $null; $label = ''; $mode = 'compose'
    switch($pick){
        '1' { $base = Join-Path $engDir 'photomode_engine.ini';         $label = 'Photomode' }
        '2' { $base = Join-Path $engDir 'optimization_only_engine.ini'; $label = 'Optimizations only' }
        '3' { $base = $null;                                            $label = 'Minimal' }
        '4' { $mode = 'merge' }
        default { $mode = 'skip' }
    }

    $cfgDir = Join-Path $env:LOCALAPPDATA 'TokyoXtremeRacer\Saved\Config\Windows'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $iniDst = Join-Path $cfgDir 'Engine.ini'

    if($mode -eq 'skip'){
        Warn 'Skipped. Exposure and fog may look wrong until the required cvars are present.'
    } else {
        if(Test-Path -LiteralPath $iniDst){
            $f = Get-Item -LiteralPath $iniDst
            if($f.IsReadOnly){ $f.IsReadOnly = $false }
            $bak = "$iniDst.bak." + (Get-Date -Format 'yyyyMMdd_HHmmss')
            Copy-Item -LiteralPath $iniDst -Destination $bak
            Ok "Backed up existing Engine.ini -> $(Split-Path $bak -Leaf)"
        }
        if($mode -eq 'merge'){
            Merge-Cvars $iniDst (@('[ConsoleVariables]') + $FogCvars + $ExpCvars)
            Ok 'Merged the required cvars at the end of your Engine.ini.'
        } else {
            $baseLines = @()
            if($base){
                if(Test-Path -LiteralPath $base){ $baseLines = @(Get-Content -LiteralPath $base) }
                else { Warn "Base profile not found ($([IO.Path]::GetFileName($base))) - using Minimal instead."; $label = 'Minimal (fallback)' }
            }
            WriteLines $iniDst (Compose-Ini $baseLines)
            Ok "Installed Engine.ini profile: $label."
        }
        (Get-Item -LiteralPath $iniDst).IsReadOnly = $true
        Ok 'Set Engine.ini read-only (stops the game overwriting it).'
    }

} finally {
    if(Test-Path -LiteralPath $tmp){ Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
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
