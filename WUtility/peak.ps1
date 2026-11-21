#Requires -Version 5.1
<#
.SYNOPSIS
    WUtility - a Windows setup / debloat / config tool, WinUtil-style but scriptable.

.DESCRIPTION
    Two ways to use it:

    GUI (like WinUtil):
        .\peak.ps1

    Linux-style CLI (WinUtil's missing superpower):
        .\peak.ps1 -List
        .\peak.ps1 -Tweaks privacy,performance -Backup
        .\peak.ps1 -Install firefox,vscode,7zip
        .\peak.ps1 -Debloat -RestorePoint
        .\peak.ps1 -UndoTeaks privacy          (oops, undo)
        .\peak.ps1 -DryRun -Everything         (preview without touching anything)

.EXAMPLE
    .\peak.ps1 -Install vscode,git -Tweaks ui,privacy -Updates security
#>

[CmdletBinding(PositionalBinding=$false)]
param(
    # ---- Selections ----
    [Alias('t')]
    [string[]]$Tweaks,            # apply tweaks by id or category (see -List)
    [Alias('u')]
    [string[]]$UndoTweaks,        # revert tweaks by id or category
    [Alias('i')]
    [string[]]$Install,           # winget ids or catalog ids: -Install firefox,vscode
    [string]$Updates,             # default | security | disable | retry
    [switch]$Debloat,             # remove consumer bloat apps + telemetry tasks
    [string[]]$Features,          # enable windows features: wsl,hyperv,sandbox,net35
    [switch]$Everything,          # all tweaks
    # ---- Safety / utility ----
    [switch]$Backup,              # export affected registry keys first
    [string]$RestoreBackup,       # re-import a backup folder from Documents\Peak\backups\<name>
    [switch]$RestorePoint,        # create a system restore point first
    [switch]$DryRun,              # show what would happen, change nothing
    [switch]$List,                # print catalog and exit (no admin needed)
    [switch]$NoGui,               # CLI even with no other args
    [switch]$SkipElevation,       # don't auto-relaunch as admin
    # ---- Internal ----
    [string[]]$WorkerTasks       # internal: GUI spawns hidden worker with tasks like 'install:id,id' ('|'-separated)
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
#  ONE-LINE HOSTING (Chris Titus / WinUtil style)
#  Host this file somewhere (GitHub Gist, website...), paste the RAW url
#  below ONCE, and then anyone can run it with a single command and zero
#  files:
#
#      irm https://your-url | iex        <- opens the GUI
#      & ([scriptblock]::Create((irm https://your-url))) -List
#      & ([scriptblock]::Create((irm https://your-url))) -Install vscode,git
#
#  The URL must be the RAW text link (the one that shows the code, not the
#  web page). You can shorten it with tinyurl.com so it's easy to type.
# ------------------------------------------------------------------
$Script:HostedUrl = ''    # set to e.g. 'https://gist.githubusercontent.com/you/<id>/raw/WUtility.ps1'

# The script's own file path - only exists when run from a file on disk.
# When run from memory (`irm url | iex`) we cache a copy from $Script:HostedUrl
# so elevation + background workers can re-invoke it.
$Script:ScriptFile = try { $PSCommandPath } catch { $null }
if ($Script:HostedUrl -and -not $Script:ScriptFile) {
    try {
        $Script:ScriptFile = Join-Path $env:TEMP 'WUtility.ps1'
        Invoke-WebRequest -UseBasicParsing -Uri $Script:HostedUrl -OutFile $Script:ScriptFile
    } catch { $Script:ScriptFile = $null }
}

# Data location: portable if the script's own folder is writable (USB/shared),
# otherwise falls back to Documents — works from anywhere on any PC.
$Script:PeakRoot = try {
    $dir = Split-Path -Parent $Script:ScriptFile
    $probe = Join-Path $dir ('.wutility-write-test-' + [guid]::NewGuid().ToString('N').Substring(0,4) + '.tmp')
    Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    Join-Path $dir 'WUtility-Data'
} catch {
    Join-Path $env:USERPROFILE 'Documents\WUtility'
}
$Script:BackupRoot = Join-Path $Script:PeakRoot 'backups'
$Script:LogFile    = Join-Path $Script:PeakRoot 'peak.log'
$Script:IsDryRun   = [bool]$DryRun
$Script:BackupDir  = $null

# ============================================================
#  Logging / helpers
# ============================================================
function Write-PeakLog {
    param([string]$Message, [ValidateSet('info','ok','warn','err','dim')][string]$Level = 'info')
    $stamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $prefix = switch ($Level) {
        'ok'   { '[+] ' }
        'warn' { '[!] ' }
        'err'  { '[E] ' }
        'dim'  { '    ' }
        default{ '[*] ' }
    }
    try {
        if (-not (Test-Path $Script:PeakRoot)) { New-Item -ItemType Directory -Path $Script:PeakRoot -Force | Out-Null }
        Add-Content -Path $Script:LogFile -Value "$stamp $prefix$Message" -ErrorAction SilentlyContinue
        if ($env:WUTILITY_GUI_LOG) { Add-Content -Path $env:WUTILITY_GUI_LOG -Value "$stamp $prefix$Message" -ErrorAction SilentlyContinue }
    } catch { }
    if ($Level -eq 'dim')   { Write-Host $prefix$Message -ForegroundColor DarkGray  -ErrorAction SilentlyContinue }
    elseif ($Level -eq 'ok'){ Write-Host $prefix$Message -ForegroundColor Green        -ErrorAction SilentlyContinue }
    elseif ($Level -eq 'warn'){ Write-Host $prefix$Message -ForegroundColor Yellow     -ErrorAction SilentlyContinue }
    elseif ($Level -eq 'err'){ Write-Host $prefix$Message -ForegroundColor Red         -ErrorAction SilentlyContinue }
    else { Write-Host $prefix$Message -ErrorAction SilentlyContinue }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSelf {
    if (-not $Script:ScriptFile) {
        Write-PeakLog 'Cannot elevate: run PowerShell as Administrator, or set $Script:HostedUrl in the script.' 'err'
        return
    }
    $argsList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$Script:ScriptFile`"")
    foreach ($p in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$p]
        if ($p -in @('SkipElevation','WorkerTasks')) { continue }
        switch -Wildcard ($v.GetType().Name) {
            'SwitchParameter' { if ($v) { $argsList += "-$p" } }
            'String[]'        { $argsList += "-$p"; $argsList += ($v | ForEach-Object { "`"$_`"" }) }
            'String'          { $argsList += "-$p"; $argsList += "`"$v`"" }
            default           { if ($v) { $argsList += "-$p" } }
        }
    }
    Write-PeakLog 'Elevating to Administrator...' 'warn'
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList ($argsList -join ' ') -Verb RunAs
    } catch {
        Write-PeakLog ("Elevation declined or failed: {0}" -f $_.Exception.Message) 'err'
    }
}

function Invoke-PeakRestorePoint {
    if ($Script:IsDryRun) { Write-PeakLog 'DRY-RUN: would create system restore point' 'dim'; return }
    Write-PeakLog 'Creating system restore point (may take a moment)...'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'WUtility snapshot' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-PeakLog 'Restore point created.' 'ok'
    } catch {
        Write-PeakLog ("Could not create restore point (often blocked within 24h of the last one): {0}" -f $_.Exception.Message) 'warn'
    }
}

function Backup-RegistryValue {
    param([string]$Path, [string]$Name)
    if ($Script:IsDryRun -or -not $Script:BackupDir) { return }
    $safe = ($Path -replace '[:\\]', '_')
    $file = Join-Path $Script:BackupDir ($safe + '.reg.txt')
    $line = "{0}|{1}|{2}" -f $Path, $Name,
        ((Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue).$Name)
    Add-Content -LiteralPath $file -Value $line -ErrorAction SilentlyContinue
}

function Invoke-BackupExport {
    param([string[]]$Paths, [string]$Tag)
    if ($Script:IsDryRun) { Write-PeakLog 'DRY-RUN: would back up registry keys' 'dim'; return $null }
    if (-not $Script:BackupDir) {
        $name = (Get-Date).ToString('yyyyMMdd_HHmmss')
        if ($Tag) { $name = "$name-$Tag" }
        $Script:BackupDir = Join-Path $Script:BackupRoot $name
        New-Item -ItemType Directory -Path $Script:BackupDir -Force | Out-Null
    }
    foreach ($p in ($Paths | Where-Object { $_ })) {
        $hive = ($p -split '\\')[0] -replace 'HKLM:','HKLM' -replace 'HKCU:','HKCU'
        $sub  = ($p -split '\\') | Select-Object -Skip 1
        $regPath = $hive + '\' + ($sub -join '\')
        $safe = $regPath -replace '(^[\w]+\\)','' -replace '[\\/]','_'
        # reg.exe writes "ERROR" to stderr for missing keys - with $ErrorActionPreference
        # =Stop that would crash the whole run, so relax it for this call only.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { reg.exe export $regPath (Join-Path $Script:BackupDir ($safe + '.reg')) /y 2>$null } catch { }
        $ErrorActionPreference = $prevEap
    }
    Write-PeakLog ("Registry backup: {0}" -f $Script:BackupDir) 'ok'
    return $Script:BackupDir
}

function Invoke-RestoreBackup {
    param([string]$Name)
    $dir = if (Test-Path $Name) { $Name } else { Join-Path $Script:BackupRoot $Name }
    if (-not (Test-Path $dir)) { Write-PeakLog ("Backup not found: {0}" -f $dir) 'err'; return }
    Write-PeakLog ("Restoring backup: {0}" -f $dir)
    Get-ChildItem -Path $dir -Filter *.reg | ForEach-Object {
        if ($Script:IsDryRun) { Write-PeakLog ("DRY-RUN: reg import {0}" -f $_.Name) 'dim'; return }
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { $null = reg.exe import $_.FullName 2>&1 } catch { }
        $ErrorActionPreference = $prevEap
        Write-PeakLog ("  imported {0}" -f $_.Name) 'dim'
    }
    Write-PeakLog 'Backup restored. Restart explorer or reboot to see every change.' 'ok'
}

function Get-WingetPath {
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    $loc = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $loc) { return $loc }
    return $null
}

# Fresh Windows installs often lack winget (App Installer). Try to self-install it
# per-user (no admin needed) so WUtility works on any PC out of the box.
function Try-EnsureWinget {
    if (Get-WingetPath) { return $true }
    Write-PeakLog 'winget is missing - attempting automatic install (can take up to a minute)...' 'warn'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
    } catch {
        Write-PeakLog ("Automatic winget install failed: {0}" -f $_.Exception.Message) 'warn'
    }
    if (-not (Get-WingetPath)) {
        Write-PeakLog 'Could not install winget automatically. Open the Microsoft Store, install "App Installer", then re-run.' 'err'
        return $false
    }
    Write-PeakLog 'winget installed successfully.' 'ok'
    return $true
}

# Winget ids of everything currently installed. One fast `winget export` call,
# cached for 1 hour so the GUI load and repeated installs stay snappy.
function Get-InstalledWingetIds {
    param([switch]$ForceFresh)
    $cache = Join-Path $Script:PeakRoot 'installed-cache.json'
    if (-not $ForceFresh -and (Test-Path $cache)) {
        try {
            $age = ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalHours
            if ($age -lt 1) {
                $parsed = ConvertFrom-Json (Get-Content $cache -Raw)
                return @($parsed)   # PS5.1 emits JSON arrays as ONE object; unwrap via var, not @() inline
            }
        } catch { }
    }
    $winget = Get-WingetPath
    if (-not $winget) { return @() }
    $tmp = Join-Path $env:TEMP ('peak-export-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json')
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try { & $winget export -o $tmp --accept-source-agreements 2>$null | Out-Null } catch { }
    $ErrorActionPreference = $prevEap
    $ids = @()
    try {
        if (Test-Path $tmp) {
            $json = Get-Content $tmp -Raw | ConvertFrom-Json
            foreach ($src in $json.Sources) {
                foreach ($p in $src.Packages) { if ($p.PackageIdentifier) { $ids += $p.PackageIdentifier } }
            }
        }
    } catch { }
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $ids = @($ids | Sort-Object -Unique)
    try { $ids | ConvertTo-Json | Set-Content $cache -Encoding UTF8 } catch { }
    return $ids
}

function Check-AppInstalled { param([string]$AppId)
    $app = $Script:Apps[$AppId]
    if (-not $app) { return $false }
    return ((Get-InstalledWingetIds) -contains $app.Winget)
}

# ============================================================
#  Catalog: tweaks / apps / bloat / features / updates
# ============================================================
$Script:TweakDefs = [ordered]@{
    # ---- Privacy ---------------------------------------------------------------------------
    'privacy.telemetry' = @{ Category='Privacy'; Name='Disable telemetry & data collection'; Keys=@(
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='AllowTelemetry'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Name='AllowTelemetry'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name='TailoredExperiencesWithDiagnosticDataEnabled'; Type='DWord'; Value=0; Revert=1}
    ); Services=@('DiagTrack'); Tasks=@() }
    'privacy.activityhistory' = @{ Category='Privacy'; Name='Activity history & cloud sync'; Keys=@(
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='EnableActivityFeed'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='PublishUserActivities'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='UploadUserActivities'; Type='DWord'; Value=0; Revert=1}
    ); Services=@(); Tasks=@() }
    'privacy.errorreporting' = @{ Category='Privacy'; Name='Disable error / crash reporting (WER)'; Keys=@(
        @{Path='HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'; Name='Disabled'; Type='DWord'; Value=1; Revert=0}
    ); Services=@('wercplsupport'); Tasks=@('\Microsoft\Windows\Windows Error Reporting\QueueReporting') }
    'privacy.feedback' = @{ Category='Privacy'; Name='Stop feedback & experience prompts'; Keys=@(
        @{Path='HKCU:\Software\Microsoft\Siuf\Rules'; Name='NumberOfSIUFInPeriod'; Type='DWord'; Value=0; Revert=$null}
        @{Path='HKCU:\Software\Microsoft\Siuf\Rules'; Name='PeriodInNanoSeconds'; Type='Delete'; Value=$null; Revert=$null}
    ); Services=@(); Tasks=@() }
    'privacy.cortana' = @{ Category='Privacy'; Name='Disable Cortana & web suggestions in search'; Keys=@(
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name='AllowCortana'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name='DisableSearchBoxSuggestions'; Type='DWord'; Value=1; Revert=0}
    ); Services=@(); Tasks=@() }
    'privacy.lockscreenads' = @{ Category='Privacy'; Name='Ads, tips & suggestions off'; Keys=@(
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338387Enabled'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338388Enabled'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338389Enabled'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-310093Enabled'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SilentInstalledAppsEnabled'; Type='DWord'; Value=0; Revert=1}
    ); Services=@(); Tasks=@() }
    'privacy.location' = @{ Category='Privacy'; Name='Disable location & sensors service'; Keys=@(
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationSensors'; Name='DisableLocation'; Type='DWord'; Value=1; Revert=0}
    ); Services=@('lfsvc'); Tasks=@() }
    # ---- Performance -----------------------------------------------------------------------
    'perf.visualeffects' = @{ Category='Performance'; Name=' Trim visual effects for speed'; Keys=@(
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name='VisualFXSetting'; Type='DWord'; Value=2; Revert=0}
        @{Path='HKCU:\Control Panel\Desktop'; Name='MenuShowDelay'; Type='String'; Value='0'; Revert='400'}
        @{Path='HKCU:\Software\Microsoft\Windows\DWM'; Name='EnableAeroPeek'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKCU:\Software\Microsoft\Windows\DWM'; Name='TaskbarAnimations'; Type='DWord'; Value=0; Revert=1}
    ); Services=@(); Tasks=@() }
    'perf.gamedvr' = @{ Category='Performance'; Name='Disable Xbox Game DVR / Game Bar recording'; Keys=@(
        @{Path='HKCU:\System\GameConfigStore'; Name='GameDVR_Enabled'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name='AllowGameDVR'; Type='DWord'; Value=0; Revert=1}
    ); Services=@(); Tasks=@() }
    'perf.ultimatepower' = @{ Category='Performance'; Name='Ultimate Performance power plan'; Keys=@(); Services=@(); Tasks=@()
        ApplyCommand  = "powercfg -duplicatescheme e9a42b02-d5df-448d-aa66-38f4dd1c4b4b"
        RevertCommand = "powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e" }
    'perf.hibernate' = @{ Category='Performance'; Name='Disable hibernation (frees hiberfil.sys disk space)'; Keys=@(); Services=@(); Tasks=@()
        ApplyCommand  = "powercfg /hibernate off"
        RevertCommand = "powercfg /hibernate on" }
    # ---- UI / Explorer ---------------------------------------------------------------------
    'ui.fileextensions' = @{ Category='UI'; Name='Always show file extensions'; Keys=@(
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='HideFileExt'; Type='DWord'; Value=0; Revert=1}
    ); Services=@(); Tasks=@() }
    'ui.hiddenfiles' = @{ Category='UI'; Name='Show hidden & protected OS files'; Keys=@(
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='Hidden'; Type='DWord'; Value=1; Revert=2}
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='ShowSuperHidden'; Type='DWord'; Value=1; Revert=0}
    ); Services=@(); Tasks=@() }
    'ui.openthispc' = @{ Category='UI'; Name='Explorer opens to This PC (not Quick Access)'; Keys=@(
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='LaunchTo'; Type='DWord'; Value=1; Revert=2}
    ); Services=@(); Tasks=@() }
    'ui.taskbarleft' = @{ Category='UI'; Name='Align taskbar left (Windows 11)'; Keys=@(
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarAl'; Type='DWord'; Value=0; Revert=1}
    ); Services=@(); Tasks=@() }
    'ui.taskbarcleanup' = @{ Category='UI'; Name='Remove Widgets & Chat/Teams icons from taskbar'; Keys=@(
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarDa'; Type='DWord'; Value=0; Revert=1}
        @{Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarMn'; Type='DWord'; Value=0; Revert=1}
    ); Services=@(); Tasks=@() }
    'ui.stickykeys' = @{ Category='UI'; Name='No popup when pressing Shift 5x (Sticky Keys)'; Keys=@(
        @{Path='HKCU:\Control Panel\Accessibility\StickyKeys'; Name='Flags'; Type='String'; Value='506'; Revert='510'}
        @{Path='HKCU:\Control Panel\Accessibility\Keyboard Response'; Name='Flags'; Type='String'; Value='122'; Revert='126'}
        @{Path='HKCU:\Control Panel\Accessibility\ToggleKeys'; Name='Flags'; Type='String'; Value='58'; Revert='62'}
    ); Services=@(); Tasks=@() }
    'ui.detailedbsod' = @{ Category='UI'; Name='Show detailed BSOD info instead of sad face QR'; Keys=@(
        @{Path='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name='DisplayParameters'; Type='DWord'; Value=1; Revert=0}
    ); Services=@(); Tasks=@() }
}

$Script:Bloat = @(
    'Microsoft.549981C3F5F10'   # Cortana
    'Clipchamp.Clipchamp'
    'Microsoft.BingNews'
    'Microsoft.BingWeather'
    'Microsoft.BingFinance'
    'Microsoft.BingSports'
    'Microsoft.BingSearch'
    'Microsoft.GamingApp'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.Microsoft3DViewer'
    'Microsoft.MicrosoftStickyNotes'
    'Microsoft.MixedReality.Portal'
    'Microsoft.News'
    'Microsoft.People'
    'Microsoft.PowerAutomateDesktop'
    'Microsoft.SkypeApp'
    'Microsoft.Todos'
    'Microsoft.Wallet'
    'Microsoft.Whiteboard'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.WindowsMaps'
    'Microsoft.WindowsSoundRecorder'
    'Microsoft.YourPhone'
    'Microsoft.ZuneMusic'
    'Microsoft.ZuneVideo'
    'Microsoft.OutlookForWindows'   # new Outlook (only removed if never configured)
    'Microsoft.Copilot'             # Copilot app (the taskbar button is disabled separately)
    'Microsoft.WindowsDevHome'      # Dev Home
    'MicrosoftCorporationII.QuickAssist'
    'Microsoft.QuickAssist'
    'Microsoft.OneConnect'
    'Microsoft.Print3D'
    'Microsoft.XboxApp'             # old Xbox console app (Game Bar / services untouched)
    'MicrosoftCorporationII.MicrosoftFamily'
    'MicrosoftTeams'
    'MicrosoftTeamsBootstrapper'
    'microsoft.windowscommunicationsapps'
    'ACE-Olympus'  # Hidden 'Get even worse ads' telemetered game service
)

# id -> winget id ; categories for -List and the GUI
$Script:AppCatalog = [ordered]@{
    'Browsers'      = @('google-chrome','firefox','brave','edge')
    'Development'   = @('vscode','git','python','nodejs','powershell','terminal','docker','intellij')
    'Media'         = @('spotify','vlc','handbrake','obs')
    'Utilities'     = @('7zip','notepad++','sharex','bitwarden','sumatra','everything','qbittorrent')
    'Gaming'        = @('steam','epic','heroic','overwolf')
    'Communication' = @('discord','signal','zoom','matrix')
}

$Script:Apps = @{
    'google-chrome' = @{ Winget='Google.Chrome';            Name='Google Chrome' }
    'firefox'       = @{ Winget='Mozilla.Firefox';          Name='Firefox' }
    'brave'         = @{ Winget='Brave.Brave';              Name='Brave' }
    'edge'          = @{ Winget='Microsoft.Edge';           Name='Microsoft Edge' }
    'vscode'        = @{ Winget='Microsoft.VisualStudioCode'; Name='VS Code' }
    'git'           = @{ Winget='Git.Git';                  Name='Git' }
    'python'        = @{ Winget='Python.Python.3.12';       Name='Python 3.12' }
    'nodejs'        = @{ Winget='OpenJS.NodeJS.LTS';        Name='Node.js LTS' }
    'powershell'    = @{ Winget='Microsoft.PowerShell';     Name='PowerShell 7' }
    'terminal'      = @{ Winget='Microsoft.WindowsTerminal'; Name='Windows Terminal' }
    'docker'        = @{ Winget='Docker.DockerDesktop';     Name='Docker Desktop' }
    'intellij'      = @{ Winget='JetBrains.IntelliJIDEA.Community'; Name='IntelliJ IDEA Community' }
    'spotify'       = @{ Winget='Spotify.Spotify';          Name='Spotify' }
    'vlc'           = @{ Winget='VideoLAN.VLC';             Name='VLC' }
    'handbrake'     = @{ Winget='HandBrake.HandBrake';      Name='HandBrake' }
    'obs'           = @{ Winget='OBSProject.OBSStudio';     Name='OBS Studio' }
    '7zip'          = @{ Winget='7zip.7zip';                Name='7-Zip' }
    'notepad++'     = @{ Winget='Notepad++.Notepad++';      Name='Notepad++' }
    'sharex'        = @{ Winget='ShareX.ShareX';            Name='ShareX' }
    'bitwarden'     = @{ Winget='Bitwarden.Bitwarden';      Name='Bitwarden' }
    'sumatra'       = @{ Winget='SumatraPDF.SumatraPDF';    Name='SumatraPDF' }
    'everything'    = @{ Winget='voidtools.Everything';     Name='Everything (voidtools)' }
    'qbittorrent'   = @{ Winget='qBittorrent.qBittorrent';  Name='qBittorrent' }
    'steam'         = @{ Winget='Valve.Steam';              Name='Steam' }
    'epic'          = @{ Winget='EpicGames.EpicGamesLauncher'; Name='Epic Games Launcher' }
    'heroic'        = @{ Winget='HeroicGamesLauncher.HeroicGamesLauncher'; Name='Heroic Games Launcher' }
    'overwolf'      = @{ Winget='Overwolf.Overwolf';        Name='Overwolf' }
    'discord'       = @{ Winget='Discord.Discord';          Name='Discord' }
    'signal'        = @{ Winget='OpenWhisperSystems.SignalDesktop'; Name='Signal' }
    'zoom'          = @{ Winget='Zoom.Zoom';                Name='Zoom' }
    'matrix'        = @{ Winget='Element.Element';          Name='Element (Matrix)' }
}

$Script:FeatureDefs = @{
    'wsl'     = @{ Name='Windows Subsystem for Linux'; Apply=@('dism.exe','/online','/enable-feature','/featurename:Microsoft-Windows-Subsystem-Linux','/all','/norestart')
                   Extra=@('dism.exe','/online','/enable-feature','/featurename:VirtualMachinePlatform','/all','/norestart') }
    'hyperv'  = @{ Name='Hyper-V'; Apply=@('dism.exe','/online','/enable-feature','/featurename:Microsoft-Hyper-V-All','/all','/norestart') }
    'sandbox' = @{ Name='Windows Sandbox'; Apply=@('dism.exe','/online','/enable-feature','/featurename:Containers-DisposableClientVM','/all','/norestart') }
    'net35'   = @{ Name='.NET Framework 3.5'; Apply=@('dism.exe','/online','/enable-feature','/featurename:NetFx3','/all','/norestart') }
    'vmp'     = @{ Name='Virtual Machine Platform (for WSL2/Android)'; Apply=@('dism.exe','/online','/enable-feature','/featurename:VirtualMachinePlatform','/all','/norestart') }
}

# ============================================================
#  Resolution helpers (accept ids or categories)
# ============================================================
function Resolve-TweakIds {
    param([string[]]$Requested)
    $out = @()
    foreach ($r in ($Requested | ForEach-Object { $_ -split ',' })) {
        $r = "$r".Trim().ToLower()
        if ($r -eq 'all' -or $r -eq 'everything') { $out += $Script:TweakDefs.Keys; continue }
        if ($Script:TweakDefs.Contains($r)) { $out += $r; continue }
        $cat  = $Script:TweakDefs.Keys | Where-Object { (($_ -split '\.')[0]) -eq $r -or $Script:TweakDefs[$_].Category.ToLower() -eq $r }
        $like = $Script:TweakDefs.Keys | Where-Object { $_ -like "*$r*" }
        if ($cat)  { $out += $cat }
        elseif ($like) { $out += $like }
        else { Write-PeakLog ("Unknown tweak '{0}' - run .\peak.ps1 -List" -f $r) 'warn' }
    }
    return ($out | Sort-Object -Unique)
}

function Resolve-AppIds {
    param([string[]]$Requested)
    $out = @()
    foreach ($r in ($Requested | ForEach-Object { $_ -split ',' })) {
        $r = "$r".Trim().ToLower()
        if ($r -eq 'all') { $Script:AppCatalog.Keys | ForEach-Object { $out += $Script:AppCatalog[$_] }; continue }
        if ($Script:Apps.ContainsKey($r)) { $out += $r; continue }
        if ($Script:AppCatalog.ContainsKey($r)) { $out += $Script:AppCatalog[$r]; continue }
        $like = $Script:Apps.Keys | Where-Object { ($_ -like "*$r*") -or ($Script:Apps[$_].Name -like "*$r*") -or ($Script:Apps[$_].Winget -like "*$r*") }
        if ($like) { $out += $like } else { Write-PeakLog ("Unknown app '{0}' - run .\peak.ps1 -List" -f $r) 'warn' }
    }
    return ($out | Sort-Object -Unique)
}

# ============================================================
#  Actions (shared by CLI + GUI worker)
# ============================================================
function Set-RegistryValue {
    param([hashtable]$Key, [switch]$Reverting)
    $path = $Key.Path
    $type = if ($Key.Type -eq 'Delete') { 'Delete' } else { $Key.Type }

    if ($type -eq 'Delete') {
        if ($Script:IsDryRun) { Write-PeakLog ("DRY-RUN: delete value {0}\{1}" -f $path, $Key.Name) 'dim'; return }
        try {
            if ((Test-Path $path) -and (Get-ItemProperty -LiteralPath $path -Name $Key.Name -ErrorAction SilentlyContinue)) {
                Backup-RegistryValue -Path $path -Name $Key.Name
                Remove-ItemProperty -LiteralPath $path -Name $Key.Name -ErrorAction Stop
                Write-PeakLog ("  deleted {0}\{1}" -f $path, $Key.Name) 'dim'
            } else {
                Write-PeakLog ("  not present: {0}\{1}" -f $path, $Key.Name) 'dim'
            }
        } catch { Write-PeakLog ("  could not delete {0}\{1}: {2}" -f $path, $Key.Name, $_.Exception.Message) 'warn' }
        return
    }

    $mode  = if ($Reverting) { $Key.Revert } else { $Key.Value }
    if ($null -eq $mode) {
        # no explicit value for this mode -> remove the value entirely
        Set-RegistryValue -Key @{Path=$Key.Path; Name=$Key.Name; Type='Delete'; Value=$null}
        return
    }
    $val = if ($type -eq 'String' -or $type -eq 'ExpandString') { "$mode" }
           elseif ($type -eq 'QWord') { [int64]$mode } else { [int]$mode }

    if ($Script:IsDryRun) {
        Write-PeakLog ("DRY-RUN: {0}\{1} = {2}" -f $path, $Key.Name, $val) 'dim'
        return
    }
    try {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Backup-RegistryValue -Path $path -Name $Key.Name
        New-ItemProperty -LiteralPath $path -Name $Key.Name -PropertyType $type -Value $val -Force -ErrorAction Stop | Out-Null
        Write-PeakLog ("  {0}\{1} = {2}" -f ($key.Path -split '\\')[-1], $Key.Name, $val) 'dim'
    } catch { Write-PeakLog ("  FAILED {0}\{1}: {2}" -f $path, $Key.Name, $_.Exception.Message) 'err' }
}

function Invoke-ApplyTweak {
    param([string]$Id, [switch]$Undo)
    $t = $Script:TweakDefs[$Id]
    if (-not $t) { Write-PeakLog ("No such tweak: {0}" -f $Id) 'err'; return }
    Write-PeakLog ("{0} {1}" -f ($(if ($Undo) {'Undoing'} else {'Applying'})), $t.Name)

    if ($Script:BackupDir -eq $null -and -not $Undo) { Invoke-BackupExport -Paths @($t.Keys.Path) | Out-Null }

    foreach ($k in $t.Keys) { Set-RegistryValue -Key $k -Reverting:$Undo }

    $svcTarget = if ($Undo) { 'Reverting' } else { 'Disabling' }
    foreach ($svc in $t.Services) {
        if ($Script:IsDryRun) { Write-PeakLog ("DRY-RUN: {0} service {1}" -f $svcTarget, $svc) 'dim'; continue }
        try {
            if ($Undo) { Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop; Start-Service -Name $svc -ErrorAction SilentlyContinue }
            else       { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue; Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop }
            Write-PeakLog ("  {0} service {1}" -f $svcTarget.ToLower(), $svc) 'dim'
        } catch { Write-PeakLog ("  service {0}: {1}" -f $svc, $_.Exception.Message) 'warn' }
    }

    foreach ($task in $t.Tasks) {
        if ($Script:IsDryRun) { Write-PeakLog ("DRY-RUN: {0} scheduled task {1}" -f $svcTarget, $task) 'dim'; continue }
        try {
            if ($Undo) { Enable-ScheduledTask -TaskPath ($task -replace '\\[^\\]+$','\') -TaskName ($task -split '\\')[-1] -ErrorAction Stop | Out-Null }
            else       { Disable-ScheduledTask -TaskPath ($task -replace '\\[^\\]+$','\') -TaskName ($task -split '\\')[-1] -ErrorAction Stop | Out-Null }
            Write-PeakLog ("  {0} task {1}" -f $svcTarget.ToLower(), ($task -split '\\')[-1]) 'dim'
        } catch { Write-PeakLog ("  task {0}: {1}" -f $task, $_.Exception.Message) 'warn' }
    }

    $cmd = if ($Undo) { $t['RevertCommand'] } else { $t['ApplyCommand'] }
    if ($cmd) {
        if ($Script:IsDryRun) { Write-PeakLog ("DRY-RUN: {0}" -f $cmd) 'dim' }
        else {
            try { Invoke-Expression $cmd -ErrorAction Stop; Write-PeakLog ("  ran: {0}" -f $cmd) 'dim' }
            catch { Write-PeakLog ("  command failed: {0}" -f $_.Exception.Message) 'warn' }
        }
    }
}

function Invoke-SetTweaks {
    param([string[]]$Requested, [switch]$Undo)
    $ids = Resolve-TweakIds -Requested $Requested
    if (-not $ids) { Write-PeakLog 'No tweaks matched.' 'warn'; return }
    if (-not $Undo) {
        $paths = @(); foreach ($i in $ids) { $paths += $Script:TweakDefs[$i].Keys.Path }
        Invoke-BackupExport -Paths ($paths | Sort-Object -Unique) -Tag 'tweaks' | Out-Null
    }
    foreach ($id in $ids) { Invoke-ApplyTweak -Id $id -Undo:$Undo }
    Write-PeakLog ("{0} tweaks {1}. Restart Explorer or reboot to see every change." -f ($ids | Measure-Object).Count, $(if ($Undo) {'reverted'} else {'applied'})) 'ok'
}

function Invoke-InstallApps {
    param([string[]]$Requested)
    $ids = Resolve-AppIds -Requested $Requested
    if (-not $ids) { Write-PeakLog 'No apps matched.' 'warn'; return }
    $winget = Get-WingetPath
    if (-not $winget) {
        if (-not (Try-EnsureWinget)) { return }
        $winget = Get-WingetPath
    }
    $installed = Get-InstalledWingetIds
    foreach ($id in $ids) {
        $app = $Script:Apps[$id]
        if ($installed -contains $app.Winget) {
            Write-PeakLog ("{0} is already installed - skipped." -f $app.Name) 'ok'
            continue
        }
        if ($Script:IsDryRun) { Write-PeakLog ("DRY-RUN: winget install {0} ({1})" -f $app.Winget, $app.Name) 'dim'; continue }
        Write-PeakLog ("Installing {0}..." -f $app.Name)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { & $winget install --id $app.Winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null } catch { }
        $ErrorActionPreference = $prevEap
        $code = $LASTEXITCODE
        if ($code -eq 0)      { Write-PeakLog ("{0} installed." -f $app.Name) 'ok' }
        elseif ($code -eq -1978335189 -or $code -eq -1978335135) { Write-PeakLog ("{0} already installed." -f $app.Name) 'ok' }
        else                  { Write-PeakLog ("{0} failed (winget exit {1}). Try: winget install --id {2}" -f $app.Name, $code, $app.Winget) 'warn' }
    }
    # something may have been installed - drop the detection cache so it refreshes
    if (-not $Script:IsDryRun) {
        try { Remove-Item (Join-Path $Script:PeakRoot 'installed-cache.json') -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# Bloat scan that works with or without admin (-AllUsers needs admin; falls
# back to a per-user scan so previews still work on a non-elevated console).
function Get-BloatPackages { param([string]$Name)
    if (Test-IsAdmin) {
        return @(Get-AppxPackage -Name $Name -AllUsers -ErrorAction SilentlyContinue)
    }
    return @(Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-Debloat {
    Write-PeakLog ("Debloat starting - {0} app targets..." -f $Script:Bloat.Count)
    if (-not (Test-IsAdmin)) { Write-PeakLog 'Not elevated: previewing current-user apps only (the real run auto-elevates).' 'dim' }
    $removed = 0; $present = 0
    foreach ($appx in $Script:Bloat) {
        if ($Script:IsDryRun) {
            if (Get-BloatPackages -Name $appx) { Write-PeakLog ("DRY-RUN: would remove {0}" -f $appx) 'dim' }
            continue
        }
        try {
            $found = Get-BloatPackages -Name $appx
            if ($found) {
                $present++
                $found | Remove-AppxPackage -AllUsers -ErrorAction Stop
                Write-PeakLog ("  removed {0}" -f $appx) 'dim'
                $removed++
            } else { Write-PeakLog ("  not present: {0}" -f $appx) 'dim' }
            $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$appx*" }
            foreach ($p in $prov) {
                $null = Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue
            }
        } catch { Write-PeakLog ("  {0}: {1}" -f $appx, $_.Exception.Message) 'warn' }
    }
    # Kill bloat-related scheduled tasks
    $tasks = @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Application Experience\StartupAppTask',
        '\Microsoft\Windows\Autochk\Proxy',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
    )
    foreach ($t in $tasks) {
        if ($Script:IsDryRun) { Write-PeakLog ("DRY-RUN: disable task {0}" -f $t) 'dim'; continue }
        try {
            $tn = $t -split '\\'; $name = $tn[-1]; $path = ($tn[0..($tn.Count-2)] -join '\') + '\'
            schtasks.exe /Change /TN "$path$name" /Disable *> $null
        } catch { }
    }
    # Block Office_click-to-run telem via services like CTT does
    foreach ($svc in @('DiagTrack','dmwappushservice')) {
        if (-not $Script:IsDryRun) {
            try { Stop-Service $svc -Force -ErrorAction SilentlyContinue; Set-Service $svc -StartupType Disabled -ErrorAction Stop } catch { }
        } else { Write-PeakLog 'DRY-RUN: would disable services DiagTrack, dmwappushservice' 'dim' }
    }

    # Stop Windows from silently reinstalling "suggested" bloat, and hide the
    # Widgets + Copilot taskbar buttons. All reverted automatically with -RestoreBackup.
    $debloatReg = @(
        # Content Delivery = the auto-installer for suggested/consumer apps
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='ContentDeliveryAllowed' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='OemPreInstalledAppsEnabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='PreInstalledAppsEnabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='PreInstalledAppsEverEnabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SilentInstalledAppsEnabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SystemPaneSuggestionsEnabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SoftLandingEnabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-310093Enabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338387Enabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338388Enabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338389Enabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-338393Enabled' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContent-353698Enabled' }
        # taskbar: widgets + copilot buttons
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarDa' }
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='ShowCopilotButton' }
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name='AllowNews' }
    )
    foreach ($r in $debloatReg) { $r['Type']='DWord'; $r['Value']=0; $r['Revert']=1 }
    if ($Script:IsDryRun) {
        Write-PeakLog ("DRY-RUN: would set {0} anti-reinstall / widgets / copilot registry values" -f $debloatReg.Count) 'dim'
    } else {
        foreach ($r in $debloatReg) {
            try {
                Set-RegistryValue -Key $r
            } catch { Write-PeakLog ("  reg: {0}\{1}: {2}" -f $r.Path, $r.Name, $_.Exception.Message) 'warn' }
        }
    }

    Write-PeakLog 'Debloat complete.'
    if ($Script:IsDryRun) {
        Write-PeakLog ("Dry-run finished. Nothing was removed. {0} app targets + anti-reinstall keys + telemetry tasks checked." -f $Script:Bloat.Count) 'ok'
    } else {
        Write-PeakLog ("Removed {0} of {1} targets present on this PC. Restart Explorer or reboot to see every change." -f $removed, $present) 'ok'
    }
}

function Invoke-SetUpdates {
    param([string]$Mode)
    $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    switch ($Mode) {
        'default' {
            Write-PeakLog 'Restoring Windows Update to defaults...'
            if ($Script:IsDryRun) { Write-PeakLog ("DRY-RUN: delete policy keys under {0}" -f $base) 'dim'; return }
            try { Remove-Item -LiteralPath $base -Recurse -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'DoNotConnectToWindowsUpdateInternetLocations' -ErrorAction SilentlyContinue } catch { }
            Write-PeakLog 'Updates restored to default behavior.' 'ok'
        }
        'security' {
            Write-PeakLog 'Setting updates to security-only (defer feature updates 1 year)...'
            $k = @{ Path=$base; Name='NoAutoUpdate'; Type='DWord'; Value=0; Revert=0 }
            $k2 = @{ Path=$base; Name='AUOptions'; Type='DWord'; Value=3; Revert=4 }
            $k3 = @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name='DeferFeatureUpdates'; Type='DWord'; Value=1; Revert=0 }
            $k4 = @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name='DeferFeatureUpdatesPeriodInDays'; Type='DWord'; Value=365; Revert=0 }
            $k5 = @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name='ExcludeWUDriversInQualityUpdate'; Type='DWord'; Value=1; Revert=0 }
            if ($Script:IsDryRun) { Write-PeakLog ("DRY-RUN: AUOptions=3 (notify before download), feature updates deferred 365d") 'dim'; return }
            Invoke-BackupExport -Paths @($base,'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate') -Tag 'updates' | Out-Null
            foreach ($kk in @($k,$k2,$k3,$k4,$k5)) { Set-RegistryValue -Key $kk }
            Write-PeakLog 'Windows Update: security patches only, feature updates deferred.' 'ok'
        }
        'disable' {
            Write-PeakLog 'DISABLING Windows Update (not recommended long-term)...'
            $k1 = @{ Path=$base; Name='NoAutoUpdate'; Type='DWord'; Value=1; Revert=0 }
            $k2 = @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name='DoNotConnectToWindowsUpdateInternetLocations'; Type='DWord'; Value=1; Revert=0 }
            $k3 = @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name='DisableWindowsUpdateAccess'; Type='DWord'; Value=1; Revert=0 }
            if ($Script:IsDryRun) { Write-PeakLog 'DRY-RUN: would disable Windows Update services & policies' 'dim'; return }
            Invoke-BackupExport -Paths @($base,'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate') -Tag 'updates-off' | Out-Null
            foreach ($kk in @($k1,$k2,$k3)) { Set-RegistryValue -Key $kk }
            foreach ($svc in @('wuauserv','UsoSvc','WaaSMedicSvc')) {
                try { Stop-Service $svc -Force -ErrorAction SilentlyContinue } catch { }
                try {
                    $reg = 'HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $svc
                    if (Test-Path $reg) { Set-ItemProperty -LiteralPath $reg -Name Start -Value 4 -Type DWord -ErrorAction Stop }
                } catch { }
            }
            Write-PeakLog 'Windows Update disabled. Use -Updates retry or default to undo.' 'ok'
        }
        'retry' {
            Write-PeakLog 'Forcing update check...'
            if ($Script:IsDryRun) { Write-PeakLog 'DRY-RUN: would force Windows Update check' 'dim'; return }
            try {
                $us = (New-Object -ComObject Microsoft.Update.Session)
                $sr = $us.CreateUpdateSearcher()
                $r  = $sr.Search("IsInstalled=0 and Type='Software'")
                Write-PeakLog ("{0} update(s) available." -f $r.Updates.Count) 'ok'
                if ($r.Updates.Count -gt 0) {
                    $ins = (New-Object -ComObject Microsoft.Update.UpdateColl)
                    foreach ($u in $r.Updates) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; $null = $ins.Add($u) }
                    $d = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateDownloader(); $d.Updates = $ins; $null = $d.Download()
                    $i = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateInstaller(); $i.Updates = $ins; $res = $i.Install()
                    Write-PeakLog ("Install result: {0}" -f $res.ResultCode) 'ok'
                }
            } catch { Write-PeakLog ("Update failed: {0}" -f $_.Exception.Message) 'err' }
        }
        default { Write-PeakLog ("Unknown updates mode '{0}'. Use: default | security | disable | retry" -f $Mode) 'err' }
    }
}

function Invoke-SetFeatures {
    param([string[]]$Requested)
    foreach ($r in $Requested) {
        $key = "$r".Trim().ToLower()
        if (-not $Script:FeatureDefs.ContainsKey($key)) { Write-PeakLog ("Unknown feature '{0}'. Available: {1}" -f $r, ($Script:FeatureDefs.Keys -join ', ')) 'warn'; continue }
        $f = $Script:FeatureDefs[$key]
        Write-PeakLog ("Enabling {0}..." -f $f.Name)
        if ($Script:IsDryRun) { Write-PeakLog ("DRY-RUN: {0}" -f ($f['Apply'] -join ' ')) 'dim'; continue }
        try {
            $p = Start-Process -FilePath $f['Apply'][0] -ArgumentList $f['Apply'][1..($f['Apply'].Count-1)] -Wait -PassThru -NoNewWindow
            if ($f['Extra']) { $null = Start-Process -FilePath $f['Extra'][0] -ArgumentList $f['Extra'][1..($f['Extra'].Count-1)] -Wait -PassThru -NoNewWindow }
            if ($p.ExitCode -notin @(0,3010)) { Write-PeakLog ("{0}: DISM exit {1} (may need reboot)" -f $f.Name, $p.ExitCode) 'warn' }
            else { Write-PeakLog ("{0} enabled." -f $f.Name) 'ok' }
        } catch { Write-PeakLog ("{0}: {1}" -f $f.Name, $_.Exception.Message) 'err' }
    }
}

# ============================================================
#  -List : the linux-y man-page catalog
# ============================================================
function Show-Catalog {
    Write-Host ''
    Write-Host 'WUTILITY  -  Windows, but yours' -ForegroundColor Cyan
    Write-Host ('  version 1.0  |  log: ' + $Script:LogFile)
    Write-Host ''
    Write-Host 'TWEAKS   (.\peak.ps1 -Tweaks <id|category>,...)   categories: privacy performance ui all' -ForegroundColor Yellow
    $last = ''
    foreach ($k in $Script:TweakDefs.Keys) {
        $t = $Script:TweakDefs[$k]
        if ($t.Category -ne $last) { $last = $t.Category; Write-Host ('  ' + $last) -ForegroundColor DarkCyan }
        Write-Host ('    {0,-28} {1}' -f $k, $t.Name)
    }
    Write-Host ''
    Write-Host 'APPS     (.\peak.ps1 -Install <id>,... use winget id directly too)' -ForegroundColor Yellow
    $installedIds = @()
    try { $installedIds = @(Get-InstalledWingetIds) } catch { }
    foreach ($cat in $Script:AppCatalog.Keys) {
        Write-Host ('  ' + $cat) -ForegroundColor DarkCyan
        foreach ($appId in $Script:AppCatalog[$cat]) {
            $mark = if ($installedIds -contains $Script:Apps[$appId].Winget) { '  [installed]' } else { '' }
            Write-Host ('    {0,-18} {1}{2}' -f $appId, $Script:Apps[$appId].Name, $mark)
        }
    }
    Write-Host ''
    Write-Host 'FEATURES (.\peak.ps1 -Features <id>,...)' -ForegroundColor Yellow
    foreach ($k in $Script:FeatureDefs.Keys) { Write-Host ('    {0,-16} {1}' -f $k, $Script:FeatureDefs[$k].Name) }
    Write-Host ''
    Write-Host 'UPDATES  (.\peak.ps1 -Updates <mode>)  modes: default | security | disable | retry' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'EXAMPLES' -ForegroundColor Yellow
    Write-Host '  .\peak.ps1 -Install vscode,git -Tweaks privacy,ui -Updates security -Backup'
    Write-Host '  .\peak.ps1 -Debloat -RestorePoint'
    Write-Host '  .\peak.ps1 -DryRun -Everything               # preview, change nothing'
    Write-Host '  .\peak.ps1 -UndoTweaks privacy               # revert'
    Write-Host '  .\peak.ps1 -RestoreBackup 20250101_120000    # re-import registry backup'
    Write-Host ''
}

# ============================================================
#  GUI (WPF) - with non-freezing worker
# ============================================================
$Script:CategoryLabels = @{
    'Privacy'     = 'Privacy & Telemetry'
    'Performance' = 'Performance'
    'UI'          = 'Interface & Explorer'
}

function New-SectionHeader { param([string]$Text)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text        = $Text.ToUpper()
    $tb.Foreground  = '#7FD3F5'
    $tb.FontWeight  = 'Bold'
    $tb.FontSize    = 12
    $tb.Margin      = '2,14,0,4'
    return $tb
}

function Build-TweakPanel {
    param([System.Windows.Controls.StackPanel]$Panel, [string]$CategoryPrefix, [System.Collections.Generic.List[object]]$Store)
    $last = $null
    foreach ($id in $Script:TweakDefs.Keys) {
        $t = $Script:TweakDefs[$id]
        if ($CategoryPrefix -and -not $id.StartsWith($CategoryPrefix)) { continue }
        if ($t.Category -ne $last) { $last = $t.Category; $Panel.Children.Add((New-SectionHeader -Text $Script:CategoryLabels[$last])) | Out-Null }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Tag        = $id
        $cb.Margin     = '6,2,0,2'
        $tb = New-Object System.Windows.Controls.TextBlock
        $r1 = New-Object System.Windows.Documents.Run($t.Name); $r1.Foreground = '#E4E4EE'
        $r2 = New-Object System.Windows.Documents.Run('    ' + $id); $r2.Foreground = '#676783'; $r2.FontSize = 10.5
        $tb.Inlines.Add($r1); $tb.Inlines.Add($r2)
        $cb.Content    = $tb
        $cb.DataContext = ($t.Name + ' ' + $id)
        $cb.ToolTip    = 'Registry, services and scheduled-task changes are backed up automatically before applying.'
        $Panel.Children.Add($cb) | Out-Null
        $Store.Add($cb)
    }
}

function Build-AppPanel {
    param([System.Windows.Controls.StackPanel]$Panel, [System.Collections.Generic.List[object]]$Store)
    foreach ($cat in $Script:AppCatalog.Keys) {
        $Panel.Children.Add((New-SectionHeader -Text $cat)) | Out-Null
        foreach ($appId in $Script:AppCatalog[$cat]) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content     = $Script:Apps[$appId].Name
            $cb.Margin      = '10,2,0,2'
            $cb.Tag         = $appId
            $cb.DataContext = ($Script:Apps[$appId].Name + ' ' + $appId + ' ' + $Script:Apps[$appId].Winget)
            $cb.ToolTip     = ('winget id: ' + $Script:Apps[$appId].Winget)
            $Panel.Children.Add($cb) | Out-Null
            $Store.Add($cb)
        }
    }
}

function Start-peakGUI {
    try { Add-Type -AssemblyName PresentationFramework } catch { throw }

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WUtility" Height="700" Width="980" MinHeight="560" MinWidth="840"
        WindowStartupLocation="CenterScreen" Background="#15151F" FontFamily="Segoe UI" FontSize="12.5"
        UseLayoutRounding="True">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#DCDCE8"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#DCDCE8"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#33334D"/>
      <Setter Property="Foreground" Value="#EAEAF4"/>
      <Setter Property="Padding" Value="13,6"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#4A4A6A"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#45456A"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#27273C"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#1E5B7A"/>
      <Setter Property="BorderBrush" Value="#2E7BA3"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#6E2740"/>
      <Setter Property="BorderBrush" Value="#93355A"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#A8A8C0"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Background="Transparent" CornerRadius="7,7,0,0" Padding="{TemplateBinding Padding}" Margin="3,4,3,0">
              <ContentPresenter ContentSource="Header" VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#33334D"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#252538"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TabPanel Grid.Row="0" IsItemsHost="True" Margin="2,0,0,0"/>
              <Border Grid.Row="1" Background="#20202E" CornerRadius="0,8,8,8" BorderBrush="#2E2E44" BorderThickness="1">
                <ContentPresenter ContentSource="SelectedContent"/>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#101018"/>
      <Setter Property="Foreground" Value="#E0E0EA"/>
      <Setter Property="BorderBrush" Value="#2E2E44"/>
      <Setter Property="CaretBrush" Value="#E0E0EA"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="SelectionBrush" Value="#2E6E8E"/>
    </Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="190"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="4,0,4,12">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Border Width="38" Height="38" CornerRadius="9" Background="#7A1E5B" BorderBrush="#A32E7B" BorderThickness="1" VerticalAlignment="Center">
          <TextBlock Text="W" FontSize="19" FontWeight="Bold" Foreground="#FFAEE5"
                     HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
        </Border>
        <StackPanel VerticalAlignment="Center" Margin="10,0,0,0">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="WUtility" FontSize="20" FontWeight="Bold" Foreground="#F2F2F8"/>
            <TextBlock Text="  WINDOWS SETUP &amp; DEBLOAT" FontSize="10" FontWeight="Medium" Foreground="#7FD3F5"
                       VerticalAlignment="Bottom" Margin="2,0,0,3"/>
          </StackPanel>
          <TextBlock Text="Windows, but yours" FontSize="10.5" Foreground="#5A5A78" Margin="1,0,0,0"/>
        </StackPanel>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <Border Name="chipWinget" CornerRadius="10" Background="#3A3A55" Padding="12,4" Margin="4,0">
          <TextBlock Name="lblWinget" Text="…" FontSize="11"/>
        </Border>
        <Border Name="chipAdmin" CornerRadius="10" Background="#3A3A55" Padding="12,4" Margin="4,0">
          <TextBlock Name="lblAdmin" Text="…" FontSize="11"/>
        </Border>
      </StackPanel>
    </Grid>
    <TabControl Grid.Row="1" Background="Transparent" BorderThickness="0">
      <TabItem Header="Tweaks">
        <DockPanel Margin="14">
          <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button Grid.Column="0" Name="btnAllTweaks"  Content="Select all" Margin="0,0,6,0"/>
            <Button Grid.Column="1" Name="btnNoneTweaks" Content="Select none" Margin="0,0,6,0"/>
            <Button Grid.Column="2" Name="btnApplyTweaks" Content="Apply tweaks" Margin="0,0,6,0" Style="{StaticResource BtnAccent}" ToolTip="Backup happens automatically"/>
            <Button Grid.Column="3" Name="btnUndoTweaks" Content="Undo selected" Margin="0,0,6,0" Style="{StaticResource BtnDanger}" ToolTip="Revert exactly these tweaks"/>
            <TextBox Grid.Column="5" Name="txtSearchTweaks" Width="200" FontSize="12" VerticalAlignment="Center" ToolTip="Filter tweaks"/>
          </Grid>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel Name="pnlTweaks" Margin="6,4,10,8"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>
      <TabItem Header="Install">
        <DockPanel Margin="14">
          <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal">
              <Button Name="btnAllApps"  Content="Select all" Margin="0,0,6,0"/>
              <Button Name="btnNoneApps" Content="Select none" Margin="0,0,6,0"/>
              <Button Name="btnApplyApps" Content="Install selected" Margin="0,0,14,0" Style="{StaticResource BtnAccent}" ToolTip="Already-installed apps are skipped automatically"/>
              <TextBlock Name="lblInstalled" VerticalAlignment="Center" Foreground="#8F8FA8"/>
            </StackPanel>
            <TextBox Grid.Column="1" Name="txtSearchApps" Width="200" FontSize="12" VerticalAlignment="Center" ToolTip="Filter apps"/>
          </Grid>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel Name="pnlApps" Margin="6,4,10,8"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>
      <TabItem Header="Debloat">
        <StackPanel Margin="18,16" MaxWidth="640" HorizontalAlignment="Left">
          <TextBlock Text="DEBLOAT" FontSize="13" FontWeight="Bold" Foreground="#7FD3F5" Margin="0,0,0,8"/>
          <TextBlock Foreground="#B8B8CC" LineHeight="20" TextWrapping="Wrap"
            Text="Removes consumer bloat apps (Cortana, Copilot app, new Outlook, Bing pack, Teams consumer, Solitaire, Clipchamp, News, Your Phone, Mail/Calendar, Game banners, ...), then:"/>
          <TextBlock Foreground="#9CE6A8" LineHeight="20" Margin="8,8,0,0" TextWrapping="Wrap"
            Text="•  Disables telemetry services + their scheduled tasks&#x0a;•  Blocks Windows from silently reinstalling 'suggested' apps&#x0a;•  Hides the Widgets and Copilot taskbar buttons&#x0a;•  Everything it touches is backed up first (Undo via -RestoreBackup)"/>
          <TextBlock Name="lblBloatCount" Foreground="#F0D89C" Margin="8,10,0,0" Text=""/>
          <TextBlock Foreground="#5A5A78" LineHeight="18" Margin="8,6,0,0" TextWrapping="Wrap"
            Text="Never touches: Store, Defender/security, Windows Update, Terminal, Notepad, Photos, Calculator, Paint or Snipping Tool."/>
          <CheckBox Name="chkRestorePoint" Content="Create a system restore point first (recommended)" Margin="2,14,0,2"/>
          <StackPanel Orientation="Horizontal" Margin="2,10,0,0">
            <Button Name="btnDryDebloat" Content="Preview (dry run)" Margin="0,0,8,0" ToolTip="Shows exactly what would be removed - changes nothing"/>
            <Button Name="btnDebloat" Content="Debloat now" Style="{StaticResource BtnDanger}"/>
          </StackPanel>
        </StackPanel>
      </TabItem>
      <TabItem Header="Windows Update">
        <StackPanel Margin="18,16" MaxWidth="640" HorizontalAlignment="Left">
          <TextBlock Text="WINDOWS UPDATE" FontSize="13" FontWeight="Bold" Foreground="#7FD3F5" Margin="0,0,0,8"/>
          <TextBlock Foreground="#B8B8CC" LineHeight="20"
            Text="Control Windows Update without breaking it. Current update policies are backed up automatically before any change."/>
          <StackPanel Orientation="Horizontal" Margin="2,14,0,0">
            <Button Name="btnUpdSecurity"  Content="Security-only" Margin="0,0,8,0" Style="{StaticResource BtnAccent}" ToolTip="Recommended: patches auto-install, feature updates deferred 1 year"/>
            <Button Name="btnUpdDefault"   Content="Restore defaults" Margin="0,0,8,0"/>
            <Button Name="btnUpdDisable"   Content="Disable" Margin="0,0,8,0" Style="{StaticResource BtnDanger}"/>
            <Button Name="btnUpdRetry"     Content="Force check now"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="2,14,0,0">
            <TextBlock Foreground="#8F8FA8" TextWrapping="Wrap" MaxWidth="620"
              Text="Security-only downloads patches automatically and defers feature updates by a year. Disable fully stops updates - reversible with Restore defaults."/>
          </StackPanel>
        </StackPanel>
      </TabItem>
      <TabItem Header="CLI">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <TextBlock Margin="18,16" FontFamily="Consolas" FontSize="12" Foreground="#C8C8DC" TextWrapping="Wrap" Text="peak.ps1 -List                          see every tweak / app / feature&#10;peak.ps1 -Install vscode,git,steam     install by id (winget under the hood)&#10;peak.ps1 -Tweaks privacy,ui -Backup    apply + export registry backup&#10;peak.ps1 -UndoTweaks ui                revert exactly what you changed&#10;peak.ps1 -Debloat -RestorePoint        debloat with a safety net&#10;peak.ps1 -Updates security             security-only Windows Update&#10;peak.ps1 -Features wsl,hyperv          enable Windows features&#10;peak.ps1 -Everything -DryRun           preview EVERYTHING, touch nothing&#10;peak.ps1 -RestoreBackup 20250101_...   re-import a backup&#10;&#10;One-liner once you host this file (GitHub Gist raw URL works):&#10;irm https://your.url/peak.ps1 | iex"/>
        </ScrollViewer>
      </TabItem>
    </TabControl>
    <TextBlock Grid.Row="2" Name="lblStatus" Text="Starting..." Margin="6,10,0,6"/>
    <ProgressBar Grid.Row="3" Name="pbWork" Height="4" IsIndeterminate="True" Visibility="Collapsed" Margin="4,0,4,6"/>
    <Border Grid.Row="4" Background="#0C0C13" CornerRadius="8" BorderBrush="#2E2E44" BorderThickness="1" Padding="6">
      <TextBox Name="txtOut" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
               Background="Transparent" BorderThickness="0" Foreground="#D2E8D8" TextWrapping="NoWrap"
               Padding="4"/>
    </Border>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader($xaml)
    $win    = [System.Windows.Markup.XamlReader]::Load($reader)
    $c      = @{}
    foreach ($n in 'btnAllTweaks','btnNoneTweaks','btnApplyTweaks','btnUndoTweaks',
                    'pnlTweaks','pnlApps','btnAllApps','btnNoneApps','btnApplyApps','lblWinget','chipWinget','lblAdmin','chipAdmin','lblBloatCount',
                    'lblInstalled','txtSearchTweaks','txtSearchApps','pbWork',
                    'btnDebloat','btnDryDebloat','chkRestorePoint',
                    'btnUpdDefault','btnUpdSecurity','btnUpdDisable','btnUpdRetry','txtOut','lblStatus') {
        $c[$n] = $win.FindName($n)
    }

    $tweakBoxes = New-Object 'System.Collections.Generic.List[object]'
    Build-TweakPanel -Panel $c['pnlTweaks'] -CategoryPrefix $null -Store $tweakBoxes
    $appBoxes   = New-Object 'System.Collections.Generic.List[object]'
    Build-AppPanel -Panel $c['pnlApps'] -Store $appBoxes

    # status chips (header)
    if (Test-IsAdmin) { $c['lblAdmin'].Text = 'ADMIN'; $c['chipAdmin'].Background = '#1F5C31'; $c['lblAdmin'].Foreground = '#9CE6A8' }
    else              { $c['lblAdmin'].Text = 'NOT ELEVATED'; $c['chipAdmin'].Background = '#5C4A1F'; $c['lblAdmin'].Foreground = '#F0D89C' }
    $w = Get-WingetPath
    if ($w) { $c['lblWinget'].Text = 'winget ready'; $c['chipWinget'].Background = '#1F5C31'; $c['lblWinget'].Foreground = '#9CE6A8' }
    else    { $c['lblWinget'].Text = 'winget missing'; $c['chipWinget'].Background = '#5C1F1F'; $c['lblWinget'].Foreground = '#F09C9C' }

    # GUI worker state lives at script scope so the DispatcherTimer can always see it
    $script:guiWorker = $null
    $script:guiLog    = Join-Path $env:TEMP ('peak-gui-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.log')
    $script:guiLine   = 0
    $script:guiDetectFile    = Join-Path $env:TEMP ('peak-detect-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
    $script:guiBloatFile     = Join-Path $env:TEMP ('peak-bloat-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
    $script:guiDetectPending = $false

    function Get-Checked { param($Boxes)
        @($Boxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    }

    # Actions run in a hidden child PowerShell so the GUI never freezes.
    function Invoke-GuiWorker { param([string[]]$Tasks, [string]$Label, [switch]$RestorePoint, [switch]$BackupFlag, [switch]$Dry)
        if ($script:guiWorker -and -not $script:guiWorker.HasExited) {
            $c['lblStatus'].Text = 'Another task is still running - wait for it to finish.'
            return
        }
        if (-not $Script:ScriptFile) {
            $c['lblStatus'].Text = 'Worker unavailable: set $Script:HostedUrl in the script (hosted mode) or run from a file.'
            return
        }
        $argsL = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$Script:ScriptFile`"",'-SkipElevation',
                   '-WorkerTasks', ('"{0}"' -f ($Tasks -join '|')))
        if ($RestorePoint) { $argsL += '-RestorePoint' }
        if ($BackupFlag)   { $argsL += '-Backup' }
        if ($Dry)          { $argsL += '-DryRun' }
        Remove-Item -Path $script:guiLog -Force -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path $script:guiLog -Force | Out-Null
        $env:WUTILITY_GUI_LOG = $script:guiLog   # child worker inherits this and mirrors its log into it
        $env:WUTILITY_DETECT_OUT = $script:guiDetectFile
        $env:WUTILITY_BLOAT_OUT  = $script:guiBloatFile
        $script:guiLine = 0
        $script:guiWorker = Start-Process powershell.exe -ArgumentList ($argsL -join ' ') -WindowStyle Hidden -PassThru
        $c['lblStatus'].Text = ("Running: {0}" -f $Label)
        $c['pbWork'].Visibility = 'Visible'
        $c['txtOut'].AppendText(("--- {0} ---" -f $Label) + [Environment]::NewLine)
    }

    # green badges on already-installed apps + skip note
    function Apply-InstalledMarks { param([string]$File)
        try {
            $parsed = ConvertFrom-Json (Get-Content $File -Raw)
            $installed = @($parsed)
        } catch { return }
        if (-not $installed) {
            $c['lblInstalled'].Text = 'could not scan installed apps (winget?)'
            return
        }
        $n = 0
        foreach ($b in $appBoxes) {
            $wid = $Script:Apps[$b.Tag].Winget
            if ($installed -contains $wid) {
                $n++
                $b.Content    = "$($b.Content)".Trim() + '   ✓ installed'
                $b.Foreground = '#9CE6A8'
                $b.ToolTip    = ('Already installed (' + $wid + ') - installs skip it automatically')
            }
        }
        $c['lblInstalled'].Text = ("{0} of {1} apps already installed - they are skipped on install" -f $n, $appBoxes.Count)
    }

    # never die silently - log and show GUI errors instead of closing the window
    $win.Dispatcher.add_UnhandledException([System.Windows.Threading.DispatcherUnhandledExceptionEventHandler]{
        param($s, $e)
        try { Write-PeakLog ("GUI error: {0}" -f $e.Exception.Message) 'err' } catch { }
        [void][System.Windows.MessageBox]::Show($e.Exception.Message, 'WUtility error')
        $e.Handled = $true
    })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $timer.Add_Tick({
        try {
            if ($script:guiWorker -and (Test-Path $script:guiLog)) {
                $all = @(Get-Content -Path $script:guiLog -ErrorAction SilentlyContinue)   # @() so a 1-line log is still an array
                if ($all -and $script:guiLine -lt $all.Count) {
                    for ($i = $script:guiLine; $i -lt $all.Count; $i++) { $c['txtOut'].AppendText($all[$i] + [Environment]::NewLine) }
                    $c['txtOut'].ScrollToEnd()
                    $script:guiLine = $all.Count
                }
                if ($script:guiWorker.HasExited) {
                    if ($script:guiDetectPending) {
                        $script:guiDetectPending = $false
                        Apply-InstalledMarks -File $script:guiDetectFile
                        $c['lblStatus'].Text = 'Ready.'
                        # show how much bloat was found on this PC
                        try {
                            if (Test-Path $script:guiBloatFile) {
                                $bloatFound = ConvertFrom-Json (Get-Content $script:guiBloatFile -Raw)
                                if ($bloatFound -is [System.Array]) { $n = $bloatFound.Count } else { $n = 1 }
                                if ($n -eq 0) { $c['lblBloatCount'].Text = 'No known bloat apps found on this PC. Still safe to run.' }
                                else          { $c['lblBloatCount'].Text = "$n of $($Script:Bloat.Count) bloat apps found on this PC." }
                            }
                        } catch { }
                        # a background detect may have self-installed winget - refresh the chip
                        if (Get-WingetPath) {
                            $c['lblWinget'].Text = 'winget ready'; $c['chipWinget'].Background = '#1F5C31'; $c['lblWinget'].Foreground = '#9CE6A8'
                        }
                    } else {
                        $c['lblStatus'].Text = 'Done. See output below.'
                    }
                    $c['pbWork'].Visibility = 'Collapsed'
                    $script:guiWorker = $null
                }
            }
        } catch {
            try { Write-PeakLog ("GUI tick error: {0}" -f $_.Exception.Message) 'warn' } catch { }
        }
    })

    # search filters (tweaks + apps)
    $c['txtSearchTweaks'].Add_TextChanged({
        $q = $c['txtSearchTweaks'].Text.Trim().ToLower()
        foreach ($b in $tweakBoxes) {
            $b.Visibility = if (-not $q -or ("$($b.DataContext)".ToLower()) -like "*$q*") { 'Visible' } else { 'Collapsed' }
        }
    })
    $c['txtSearchApps'].Add_TextChanged({
        $q = $c['txtSearchApps'].Text.Trim().ToLower()
        foreach ($b in $appBoxes) {
            $b.Visibility = if (-not $q -or ("$($b.DataContext)".ToLower()) -like "*$q*") { 'Visible' } else { 'Collapsed' }
        }
    })

    $c['btnAllTweaks'].Add_Click({  foreach ($b in $tweakBoxes) { $b.IsChecked = $true } })
    $c['btnNoneTweaks'].Add_Click({ foreach ($b in $tweakBoxes) { $b.IsChecked = $false } })
    $c['btnAllApps'].Add_Click({    foreach ($b in $appBoxes)   { $b.IsChecked = $true } })
    $c['btnNoneApps'].Add_Click({   foreach ($b in $appBoxes)   { $b.IsChecked = $false } })

    $c['btnApplyTweaks'].Add_Click({
        $ids = Get-Checked -Boxes $tweakBoxes
        if (-not $ids) { $c['lblStatus'].Text = 'Nothing selected in Tweaks.'; return }
        Invoke-GuiWorker -Label 'Applying tweaks (registry backed up first)' -Tasks (@('tweaks:' + ($ids -join ',')))
    })
    $c['btnUndoTweaks'].Add_Click({
        $ids = Get-Checked -Boxes $tweakBoxes
        if (-not $ids) { $c['lblStatus'].Text = 'Nothing selected in Tweaks.'; return }
        Invoke-GuiWorker -Label 'Undoing tweaks' -Tasks (@('untweaks:' + ($ids -join ',')))
    })
    $c['btnApplyApps'].Add_Click({
        $ids = Get-Checked -Boxes $appBoxes
        if (-not $ids) { $c['lblStatus'].Text = 'Nothing selected in Install.'; return }
        Invoke-GuiWorker -Label 'Installing apps via winget' -Tasks (@('install:' + ($ids -join ',')))
    })
    $c['btnDryDebloat'].Add_Click({
        Invoke-GuiWorker -Label 'Previewing debloat (dry-run)' -Tasks @('debloat') -Dry
    })
    $c['btnDebloat'].Add_Click({
        Invoke-GuiWorker -Label 'Debloating' -Tasks @('debloat') -RestorePoint:($c['chkRestorePoint'].IsChecked)
    })
    $c['btnUpdDefault'].Add_Click({  Invoke-GuiWorker -Label 'Windows Update: defaults' -Tasks @('updates:default') })
    $c['btnUpdSecurity'].Add_Click({ Invoke-GuiWorker -Label 'Windows Update: security-only' -Tasks @('updates:security') })
    $c['btnUpdDisable'].Add_Click({  Invoke-GuiWorker -Label 'Windows Update: disable' -Tasks @('updates:disable') })
    $c['btnUpdRetry'].Add_Click({    Invoke-GuiWorker -Label 'Windows Update: checking' -Tasks @('updates:retry') })

    $timer.Start()

    # scan installed apps in the background so the Install tab gets green badges
    $c['lblStatus'].Text = 'Scanning installed apps...'
    $script:guiDetectPending = $true
    Invoke-GuiWorker -Label 'Scanning installed apps (winget)' -Tasks @('detect')

    Write-PeakLog ("GUI started. Log: {0}" -f $Script:LogFile) 'dim'
    [void]$win.ShowDialog()
}

# ============================================================
#  Worker mode (spawned by GUI) - must run before GUI check
# ============================================================
if ($WorkerTasks) {
    foreach ($task in (($WorkerTasks -join '|') -split '\|')) {
        $kind, $val = ($task -split ':', 2)
        switch ($kind) {
            'tweaks'   { Invoke-SetTweaks -Requested ($val -split ',') }
            'untweaks' { Invoke-SetTweaks -Requested ($val -split ',') -Undo }
            'install'  { Invoke-InstallApps -Requested ($val -split ',') }
            'debloat'  { if ($RestorePoint) { Invoke-PeakRestorePoint }; Invoke-Debloat }
            'detect'   {
                if (-not (Get-WingetPath)) { [void](Try-EnsureWinget) }
                $ids = Get-InstalledWingetIds -ForceFresh
                if ($env:WUTILITY_DETECT_OUT) {
                    try { $ids | ConvertTo-Json | Set-Content -Path $env:WUTILITY_DETECT_OUT -Encoding UTF8 } catch { }
                }
                # also report which bloat apps are on this PC, for the GUI counter
                $findBloat = @()
                foreach ($pat in $Script:Bloat) {
                    foreach ($p in (Get-BloatPackages -Name $pat)) { $findBloat += $p.Name }
                }
                $findBloat = @($findBloat | Sort-Object -Unique)
                if ($env:WUTILITY_BLOAT_OUT) {
                    try { $findBloat | ConvertTo-Json | Set-Content -Path $env:WUTILITY_BLOAT_OUT -Encoding UTF8 } catch { }
                }
                Write-PeakLog ("Installed-app scan complete: {0} apps found, {1} bloat apps present." -f $ids.Count, $findBloat.Count) 'ok'
            }
            'updates'  { Invoke-SetUpdates -Mode $val }
            'features' { Invoke-SetFeatures -Requested ($val -split ',') }
            default    { Write-PeakLog ("Unknown worker task: {0}" -f $task) 'warn' }
        }
    }
    return
}

# ============================================================
#  CLI mode
# ============================================================
if ($List)      { Show-Catalog; return }

if ($RestoreBackup) {
    if (-not (Test-IsAdmin) -and -not $SkipElevation) { Invoke-ElevatedSelf; return }
    Invoke-RestoreBackup -Name $RestoreBackup
    return
}

$hasWork = ($Tweaks -or $UndoTweaks -or $Install -or $Updates -or $Debloat -or $Features -or $Everything)
if (-not $hasWork) {
    if ($NoGui) {
        Show-Catalog
        return
    }
    # GUI path (admin optional - many tweaks still work, but ask once)
    if (-not (Test-IsAdmin) -and -not $SkipElevation) { Invoke-ElevatedSelf; return }
    Start-peakGUI
    return
}

# hasWork = CLI
if (-not (Test-IsAdmin) -and -not $SkipElevation) { Invoke-ElevatedSelf; return }

Write-PeakLog '=== WUtility ==='
Write-PeakLog ("Dry-run: {0}" -f [bool]$Script:IsDryRun) 'dim'
if ($Everything) { $Tweaks = 'all'; $UndoTweaks = $null }

if ($RestorePoint) { Invoke-PeakRestorePoint }

if ($Tweaks)      { Invoke-SetTweaks -Requested $Tweaks }
if ($UndoTweaks)  { Invoke-SetTweaks -Requested $UndoTweaks -Undo }
if ($Install)     { Invoke-InstallApps -Requested @($Install | ForEach-Object { $_ -split ',' }) }
if ($Features)    { Invoke-SetFeatures -Requested $Features }
if ($Updates)     { Invoke-SetUpdates -Mode $Updates }
if ($Debloat)     { Invoke-Debloat }

if (-not $Script:IsDryRun) { Write-PeakLog 'All done. Reboot if prompted.' 'ok' }
else { Write-PeakLog 'Dry-run finished. Nothing was changed.' 'ok' }
