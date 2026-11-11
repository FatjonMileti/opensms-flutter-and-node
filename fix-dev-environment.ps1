#Requires -Version 5.1
<#
.SYNOPSIS
    Repairs the Windows / Flutter / Android toolchain problems found while
    building the OpenSMS gateway app on this machine.

.DESCRIPTION
    Fixes, in order:
      1. Corrupted Flutter "jdk-dir" (was: "path/to/jdk & ...exit_with_errorlevel.bat")
      2. Missing ANDROID_HOME / ANDROID_SDK_ROOT
      3. PATH ordering: standalone Dart shadowing Flutter's bundled Dart
      4. JAVA_HOME pointing at a gutted JDK (Android Studio JBR with no lib\jvm.cfg)
      5. JDK too new for Gradle 8.12 (JDK 25) -> installs Temurin 21 automatically
      6. "adb.exe" replaced by an output-swallowing wrapper (Flutter saw no devices)
      7. Bogus JVM/Dart option variables that break Gradle
      8. Windows long-path limit (Gradle/Flutter path errors)
      9. Filesystem filter driver (WiseFS) delaying/zeroing compiler output
     10. FVM project wiring (.fvmrc + .fvm\flutter_sdk junction)
     11. Project pins, stale build folders, pub get / precache, verification

    Everything that is changed is backed up first to .\backup-<timestamp>\,
    including a restore.ps1 you can run to roll the environment back.

.PARAMETER ProjectRoot
    Folder that contains app\pubspec.yaml. Defaults to the script's folder.

.PARAMETER FlutterSdk
    Flutter SDK root. Auto-detected from the FVM-managed SDK or `flutter` command.

.PARAMETER AndroidSdk
    Android SDK root. Auto-detected from local.properties / default location.

.PARAMETER JdkHome
    JDK root. Auto-detected, must be JDK 17-23 for Gradle 8.12.

.PARAMETER FlutterVersion
    Flutter version used for the FVM project wiring. Default 3.35.7.

.PARAMETER CreateEmulator
    Create an "opensms_gateway" AVD from an already-installed system image.

.PARAMETER RepairCache
    Also run `flutter pub cache repair` (slow, needs network).

.PARAMETER RunTests
    Run `flutter test` after the repair.

.PARAMETER SkipBuild
    Do not run the final `flutter build apk --debug`.

.PARAMETER SkipDownload
    Never download anything (JDK / platform-tools). Fails loudly instead.

.PARAMETER DisableWiseFilter
    Unload the WiseFS filter driver for this boot (see step 9).

.PARAMETER DryRun
    Show what would change without writing anything. Allowed without admin.

.EXAMPLE
    # Right-click PowerShell -> Run as administrator, then:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-dev-environment.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-dev-environment.ps1 -CreateEmulator -RunTests

.NOTES
    Idempotent: safe to run repeatedly. Requires admin for machine env/PATH,
    the long-path registry value, driver unload and platform-tools repair.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$FlutterSdk,
    [string]$AndroidSdk,
    [string]$JdkHome,
    [string]$FlutterVersion = '3.35.7',
    [switch]$CreateEmulator,
    [switch]$RepairCache,
    [switch]$RunTests,
    [switch]$SkipBuild,
    [switch]$SkipDownload,
    [switch]$DisableWiseFilter,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not yet populated while `-File` binds parameter defaults,
# so resolve the default here in the body instead.
if (-not $ProjectRoot) {
    if ($PSScriptRoot) {
        $ProjectRoot = $PSScriptRoot
    }
    elseif ($MyInvocation.MyCommand.Path) {
        $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    else {
        $ProjectRoot = (Get-Location).Path
    }
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

# Gradle 8.12 supports Java 8..23; AGP 8.9 needs 17+.
$MinJdkMajor = 17
$MaxJdkMajor = 23
$PreferredJdkMajor = 21
$PreferredJdkPath = 'C:\tools\jdk-21'

# ---------------------------------------------------------------------------
# Logging / result tracking
# ---------------------------------------------------------------------------
$script:Failures = 0
$script:Warnings = 0
$script:Results = New-Object System.Collections.Generic.List[object]
$script:BackupDir = Join-Path $ProjectRoot ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host ("== " + $Text) -ForegroundColor Cyan
}
function Write-Ok([string]$Text) { Write-Host ("   [ OK ] " + $Text) -ForegroundColor Green }
function Write-Warn([string]$Text) {
    Write-Host ("   [WARN] " + $Text) -ForegroundColor Yellow
    $script:Warnings++
}
function Write-Info([string]$Text) { Write-Host ("   [ .. ] " + $Text) -ForegroundColor Gray }
function Write-Fail([string]$Text) {
    Write-Host ("   [FAIL] " + $Text) -ForegroundColor Red
    $script:Failures++
}

function Add-Result([string]$Area, [string]$Status, [string]$Detail) {
    $script:Results.Add([pscustomobject]@{
            Area   = $Area
            Status = $Status
            Detail = $Detail
        })
}

function Write-TextFile([string]$Path, [string]$Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Invoke-Capture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    # Native stderr arrives as ErrorRecords. With $ErrorActionPreference='Stop',
    # Windows PowerShell 5.1 turns every java/gradle warning into a terminating
    # error, so relax it for the duration of the call only.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    [pscustomobject]@{ Output = @($output); ExitCode = $code }
}

function Get-CaptureText($Result) {
    return ((@($Result.Output) | ForEach-Object { $_.ToString() }) -join "`n").Trim()
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$AllowFailure
    )
    $result = Invoke-Capture -FilePath $FilePath -ArgumentList $ArgumentList
    foreach ($line in $result.Output) { Write-Host ("        " + $line) -ForegroundColor DarkGray }
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        throw ("'" + $FilePath + " " + ($ArgumentList -join ' ') + "' exited with code " + $result.ExitCode)
    }
    return $result.ExitCode
}

# Some security products (Wise Care 360's WiseFS filter, aggressive AV) make a
# freshly written file visible only a moment after the writer exits. Flutter and
# pub read artifacts back immediately, which is why they used to fail with
# "The Dart compiler exited unexpectedly". Wait for the size to settle.
function Wait-FileReady {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSeconds = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastSize = -1
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $size = (Get-Item -LiteralPath $Path).Length
            if ($size -gt 0 -and $size -eq $lastSize) { return $size }
            $lastSize = $size
        }
        Start-Sleep -Milliseconds 250
    }
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).Length }
    return 0
}

# ---------------------------------------------------------------------------
# Elevation / identity
# ---------------------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' OpenSMS dev environment repair' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host (" Script     : " + $PSCommandPath)
Write-Host (" Project    : " + $ProjectRoot)
Write-Host (" Admin      : " + $isAdmin)
Write-Host (" Dry run    : " + [bool]$DryRun)

if (-not $isAdmin -and -not $DryRun) {
    Write-Host ''
    Write-Host 'This script must run elevated (machine PATH, environment, registry, drivers).' -ForegroundColor Red
    Write-Host 'Close this window, start PowerShell as Administrator, and re-run:' -ForegroundColor Yellow
    Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"') -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
if (-not $DryRun) {
    New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    Write-Info ("Backups will be written to " + $script:BackupDir)
}

function Backup-Text([string]$Label, [string]$Content) {
    if ($DryRun) { return }
    Write-TextFile (Join-Path $script:BackupDir $Label) $Content
}

$machineVars = [Environment]::GetEnvironmentVariables('Machine')
$userVars = [Environment]::GetEnvironmentVariables('User')
if (-not $DryRun) {
    Backup-Text 'env-machine.txt' (($machineVars.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Value }) -join "`r`n")
    Backup-Text 'env-user.txt' (($userVars.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Value }) -join "`r`n")

    $machinePathKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $userPathKey = 'HKCU:\Environment'
    $machinePathRaw = [string](Get-Item -LiteralPath $machinePathKey).GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $userPathRaw = [string](Get-Item -LiteralPath $userPathKey).GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    Backup-Text 'path-machine.txt' $machinePathRaw
    Backup-Text 'path-user.txt' $userPathRaw
}

# ---------------------------------------------------------------------------
# Generic helpers: PE inspection, downloads, exe health
# ---------------------------------------------------------------------------
function Get-PeSubsystem([string]$Path) {
    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            $reader = New-Object IO.BinaryReader($stream)
            if ($stream.Length -lt 0x40) { return $null }
            $stream.Position = 0x3C
            $pe = $reader.ReadInt32()
            if ($pe -le 0 -or ($pe + 0x5A) -gt $stream.Length) { return $null }
            $stream.Position = $pe + 4 + 20 + 68
            return [int]$reader.ReadUInt16()
        }
        finally { $stream.Dispose() }
    }
    catch { return $null }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if ($SkipDownload) {
        throw ('Download required but -SkipDownload was given: ' + $Uri)
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Write-Info ('Downloading ' + $Uri)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec 1800
    $timer.Stop()
    Write-Ok ('Downloaded {0:N1} MB in {1:N0}s' -f ((Get-Item -LiteralPath $Destination).Length / 1MB), $timer.Elapsed.TotalSeconds)
}

function Expand-ZipTo {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

# ---------------------------------------------------------------------------
# Tool discovery: Flutter
# ---------------------------------------------------------------------------
function Resolve-FvmSdk([string]$Version) {
    $roots = @(
        (Join-Path $env:USERPROFILE 'fvm\versions'),
        (Join-Path $env:LOCALAPPDATA 'fvm\versions'),
        (Join-Path $env:APPDATA 'fvm\versions')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $candidate = Join-Path $root $Version
        if (Test-Path -LiteralPath (Join-Path $candidate 'bin\flutter.bat')) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-FlutterSdkVersion([string]$SdkPath) {
    $versionFile = Join-Path $SdkPath 'version'
    if (Test-Path -LiteralPath $versionFile) {
        $raw = (Get-Content -LiteralPath $versionFile -Raw).Trim()
        if ($raw) { return $raw }
    }
    $bat = Join-Path $SdkPath 'bin\flutter.bat'
    if (Test-Path -LiteralPath $bat) {
        $result = Invoke-Capture -FilePath $bat -ArgumentList @('--version')
        $text = Get-CaptureText $result
        if ($text -match 'Flutter\s+(\d+\.\d+\.\d+)') { return $matches[1] }
    }
    return $null
}

function Resolve-FlutterSdk {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($FlutterSdk) { $candidates.Add($FlutterSdk) }

    # Prefer an FVM-managed SDK: that is what the project pins.
    $fvm = Resolve-FvmSdk $FlutterVersion
    if ($fvm) { $candidates.Add($fvm) }

    $command = Get-Command flutter -ErrorAction SilentlyContinue
    if ($command) {
        $root = Split-Path -Parent (Split-Path -Parent $command.Source)
        if (Test-Path -LiteralPath (Join-Path $root 'bin\flutter.bat')) { $candidates.Add($root) }
    }
    foreach ($pattern in @('C:\tools\flutter*', 'C:\src\flutter', 'C:\flutter', (Join-Path $env:LOCALAPPDATA 'flutter'))) {
        foreach ($found in @(Get-Item -Path $pattern -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $found.FullName 'bin\flutter.bat')) { $candidates.Add($found.FullName) }
        }
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate 'bin\flutter.bat')) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Tool discovery: Android SDK
# ---------------------------------------------------------------------------
function Resolve-AndroidSdk {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($AndroidSdk) { $candidates.Add($AndroidSdk) }
    if ($env:ANDROID_HOME) { $candidates.Add($env:ANDROID_HOME) }
    if ($env:ANDROID_SDK_ROOT) { $candidates.Add($env:ANDROID_SDK_ROOT) }

    $localProps = Join-Path $ProjectRoot 'app\android\local.properties'
    if (Test-Path -LiteralPath $localProps) {
        foreach ($line in Get-Content -LiteralPath $localProps) {
            if ($line -match '^\s*sdk\.dir\s*=\s*(.+)$') {
                $candidates.Add(($matches[1].Trim() -replace '\\\\', '\'))
            }
        }
    }
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Android\sdk'))
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Android\Sdk'))

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if ((Test-Path -LiteralPath (Join-Path $expanded 'platforms')) -or
            (Test-Path -LiteralPath (Join-Path $expanded 'platform-tools'))) {
            return (Resolve-Path -LiteralPath $expanded).Path
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Tool discovery: JDK (validated, version-bounded)
# ---------------------------------------------------------------------------
function Get-JdkInfo([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $java = Join-Path $Path 'bin\java.exe'
    if (-not (Test-Path -LiteralPath $java)) { return $null }

    # A gutted Android Studio JBR keeps bin\java.exe but loses lib\jvm.cfg and
    # `release`, so every JVM launch dies with:
    #   Error: could not open '...\jbr\lib\jvm.cfg'
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'lib\jvm.cfg'))) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'release'))) { return $null }

    $result = Invoke-Capture -FilePath $java -ArgumentList @('-version')
    if ($result.ExitCode -ne 0) { return $null }

    $text = Get-CaptureText $result
    if ($text -notmatch 'version\s+"?(\d+)') { return $null }
    $major = [int]$matches[1]

    [pscustomobject]@{
        Path  = (Resolve-Path -LiteralPath $Path).Path
        Major = $major
        Text  = $text
    }
}

function Resolve-Jdk {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($JdkHome) { $candidates.Add($JdkHome) }
    if ($env:JAVA_HOME) { $candidates.Add($env:JAVA_HOME) }
    $candidates.Add($PreferredJdkPath)
    $candidates.Add((Join-Path $env:ProgramFiles 'Eclipse Adoptium'))
    $candidates.Add((Join-Path $env:ProgramFiles 'Java'))
    $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft'))
    $candidates.Add((Join-Path $env:ProgramFiles 'Amazon Corretto'))
    $candidates.Add((Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'))
    $candidates.Add((Join-Path $env:ProgramFiles 'Android\Android Studio1\jbr'))
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Android\Android Studio\jbr'))
    }
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Android Studio\jbr'))

    $expanded = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        # Version folders (Eclipse Adoptium\jdk-21.0.1+12, Java\jdk-17, ...)
        if (Test-Path -LiteralPath (Join-Path $candidate 'bin\java.exe')) {
            $expanded.Add($candidate)
        }
        else {
            foreach ($child in @(Get-ChildItem -LiteralPath $candidate -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
                $expanded.Add($child.FullName)
            }
        }
    }

    $rejected = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $expanded) {
        $info = Get-JdkInfo $candidate
        if (-not $info) {
            if (Test-Path -LiteralPath (Join-Path $candidate 'bin\java.exe')) {
                $rejected.Add(($candidate + ' (broken: missing lib\jvm.cfg / release)'))
            }
            continue
        }
        if ($info.Major -lt $MinJdkMajor -or $info.Major -gt $MaxJdkMajor) {
            $rejected.Add(($info.Path + ' (JDK ' + $info.Major + ' outside ' + $MinJdkMajor + '..' + $MaxJdkMajor + ')'))
            continue
        }
        return $info
    }

    foreach ($entry in $rejected) { Write-Warn ('Skipping JDK: ' + $entry) }
    return $null
}

function Install-TemurinJdk([int]$Major) {
    if ($SkipDownload) {
        throw ('No usable JDK ' + $MinJdkMajor + '..' + $MaxJdkMajor + ' found and -SkipDownload was given.')
    }
    $zip = Join-Path $env:TEMP ('temurin' + $Major + '.zip')
    $url = 'https://api.adoptium.net/v3/binary/latest/' + $Major + '/ga/windows/x64/jdk/hotspot/normal/eclipse'
    Invoke-Download -Uri $url -Destination $zip

    $staging = Join-Path $env:TEMP ('temurin' + $Major + '-staging')
    Expand-ZipTo -ZipPath $zip -Destination $staging
    $inner = Get-ChildItem -LiteralPath $staging -Directory | Select-Object -First 1
    if (-not $inner) { throw 'The downloaded JDK archive did not contain a folder.' }

    $target = $PreferredJdkPath
    if (Test-Path -LiteralPath $target) {
        $old = $target + '.old-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Move-Item -LiteralPath $target -Destination $old
        Write-Info ('Moved previous JDK to ' + $old)
    }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Move-Item -LiteralPath $inner.FullName -Destination $target
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

    $info = Get-JdkInfo $target
    if (-not $info) { throw ('Installed JDK at ' + $target + ' but it does not validate.') }
    Write-Ok ('Installed JDK ' + $info.Major + ' at ' + $target)
    return $info
}

# ---------------------------------------------------------------------------
# Tool discovery: adb / platform-tools
# ---------------------------------------------------------------------------
function Test-AdbHealthy([string]$AdbPath) {
    if (-not (Test-Path -LiteralPath $AdbPath)) { return $false }
    $result = Invoke-Capture -FilePath $AdbPath -ArgumentList @('version')
    $text = Get-CaptureText $result
    # The broken "adb" on this machine is a GUI-subsystem self-extracting
    # wrapper: it exits 0 and prints nothing at all.
    return ($result.ExitCode -eq 0 -and $text -match 'Android Debug Bridge')
}

function Repair-PlatformTools([string]$SdkRoot) {
    $sdkTools = Join-Path $SdkRoot 'platform-tools'
    $sdkAdb = Join-Path $sdkTools 'adb.exe'

    if (Test-AdbHealthy $sdkAdb) {
        Write-Ok 'adb.exe in the Android SDK works.'
        Add-Result 'platform-tools' 'OK' 'adb.exe healthy'
        return $true
    }

    if ($DryRun) {
        Write-Info 'Would repair adb.exe in the Android SDK (wrapper / missing binary).'
        Add-Result 'platform-tools' 'DRYRUN' 'adb.exe broken'
        return $false
    }

    Write-Warn 'adb.exe is broken (wrapper that prints nothing, or missing).'
    $subsystem = Get-PeSubsystem $sdkAdb
    if ($null -ne $subsystem) {
        Write-Info ('adb.exe PE subsystem = ' + $subsystem + ' (a console tool should be 3)')
    }

    if (-not (Test-Path -LiteralPath $sdkTools)) {
        New-Item -ItemType Directory -Path $sdkTools -Force | Out-Null
    }
    if (Test-Path -LiteralPath $sdkAdb) {
        $backup = Join-Path $sdkTools ('adb.broken-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.exe')
        Copy-Item -LiteralPath $sdkAdb -Destination $backup -Force
        Write-Info ('Backed up broken adb.exe to ' + $backup)
    }

    # 1) Official sdkmanager first.
    $sdkManager = Join-Path $SdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (Test-Path -LiteralPath $sdkManager) {
        Write-Info 'Trying: sdkmanager --install platform-tools'
        try {
            Invoke-Native -FilePath $sdkManager -ArgumentList @('--install', 'platform-tools') -AllowFailure | Out-Null
        }
        catch {
            Write-Warn ('sdkmanager failed: ' + $_.Exception.Message)
        }
        if (Test-AdbHealthy $sdkAdb) {
            Write-Ok 'platform-tools reinstalled via sdkmanager.'
            Add-Result 'platform-tools' 'FIXED' 'reinstalled via sdkmanager'
            return $true
        }
    }

    # 2) Official Google zip.
    try {
        $zip = Join-Path $env:TEMP 'platform-tools-windows.zip'
        Invoke-Download -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -Destination $zip
        $staging = Join-Path $env:TEMP 'platform-tools-staging'
        Expand-ZipTo -ZipPath $zip -Destination $staging
        $source = Join-Path $staging 'platform-tools'
        if (-not (Test-Path -LiteralPath $source)) { $source = $staging }

        Copy-Item -Path (Join-Path $source '*') -Destination $sdkTools -Recurse -Force
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Fail ('Could not download platform-tools: ' + $_.Exception.Message)
        Add-Result 'platform-tools' 'FAILED' 'download failed'
        return $false
    }

    if (Test-AdbHealthy $sdkAdb) {
        Write-Ok 'platform-tools replaced with the official Google build.'
        Add-Result 'platform-tools' 'FIXED' 'official platform-tools installed'
        return $true
    }

    Write-Fail 'adb.exe still does not work. Install platform-tools manually from Google.'
    Add-Result 'platform-tools' 'FAILED' 'adb still broken'
    return $false
}

# ---------------------------------------------------------------------------
# FVM project wiring
# ---------------------------------------------------------------------------
function Set-FvmProject {
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][string]$SdkPath
    )
    $version = Get-FlutterSdkVersion $SdkPath
    if (-not $version) { $version = $FlutterVersion }

    $rcPath = Join-Path $AppRoot '.fvmrc'
    $rcBody = '{ "flutter": "' + $version + '" }'
    $existing = $null
    if (Test-Path -LiteralPath $rcPath) { $existing = (Get-Content -LiteralPath $rcPath -Raw).Trim() }

    if ($existing -ne $rcBody) {
        if ($DryRun) {
            Write-Info ('Would write .fvmrc with flutter ' + $version)
        }
        else {
            if ($existing) { Backup-Text 'fvmrc.json' $existing }
            Write-TextFile $rcPath ($rcBody + "`n")
            Write-Ok ('.fvmrc pins Flutter ' + $version)
        }
    }
    else {
        Write-Ok ('.fvmrc already pins Flutter ' + $version)
    }

    $fvmDir = Join-Path $AppRoot '.fvm'
    $link = Join-Path $fvmDir 'flutter_sdk'

    $alreadyLinked = $false
    if (Test-Path -LiteralPath $link) {
        $target = (Get-Item -LiteralPath $link -Force).Target
        if ($target) {
            $targetText = (@($target) -join '')
            if ($targetText.TrimEnd('\') -ieq $SdkPath.TrimEnd('\')) { $alreadyLinked = $true }
        }
    }

    if ($alreadyLinked) {
        Write-Ok ('.fvm\flutter_sdk already points at ' + $SdkPath)
        Add-Result 'FVM' 'OK' ('flutter_sdk -> ' + $SdkPath)
        return
    }

    if ($DryRun) {
        Write-Info ('Would link .fvm\flutter_sdk -> ' + $SdkPath)
        Add-Result 'FVM' 'DRYRUN' 'junction would be created'
        return
    }

    if (-not (Test-Path -LiteralPath $fvmDir)) { New-Item -ItemType Directory -Path $fvmDir -Force | Out-Null }
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Recurse -Force -ErrorAction SilentlyContinue }

    $output = & cmd.exe /c ('mklink /J "' + $link + '" "' + $SdkPath + '"') 2>&1
    if (Test-Path -LiteralPath (Join-Path $link 'bin\flutter.bat')) {
        Write-Ok ('Linked .fvm\flutter_sdk -> ' + $SdkPath)
        Add-Result 'FVM' 'FIXED' 'junction created'
    }
    else {
        Write-Fail ('Could not create the .fvm\flutter_sdk junction: ' + (($output | ForEach-Object { $_.ToString() }) -join ' '))
        Add-Result 'FVM' 'FAILED' 'junction failed'
    }
}

# ---------------------------------------------------------------------------
# 1/11  Discovery
# ---------------------------------------------------------------------------
Write-Step '1/11  Locating Flutter, JDK and Android SDK'

$FlutterSdk = Resolve-FlutterSdk
if (-not $FlutterSdk) {
    Write-Fail 'Flutter SDK not found. Pass -FlutterSdk "C:\path\to\flutter".'
    exit 1
}
Write-Ok ('Flutter SDK : ' + $FlutterSdk)

$jdkInfo = Resolve-Jdk
if (-not $jdkInfo) {
    Write-Warn 'No JDK in the supported range (' + $MinJdkMajor + '..' + $MaxJdkMajor + ') was found.'
    if ($DryRun) {
        Write-Info ('Would install Temurin ' + $PreferredJdkMajor + ' to ' + $PreferredJdkPath)
        Add-Result 'JDK' 'DRYRUN' 'would install Temurin'
        $jdkInfo = [pscustomobject]@{ Path = $PreferredJdkPath; Major = $PreferredJdkMajor; Text = '' }
    }
    else {
        try {
            $jdkInfo = Install-TemurinJdk $PreferredJdkMajor
            Add-Result 'JDK' 'FIXED' ('installed Temurin ' + $jdkInfo.Major)
        }
        catch {
            Write-Fail ('JDK install failed: ' + $_.Exception.Message)
            Add-Result 'JDK' 'FAILED' $_.Exception.Message
            exit 1
        }
    }
}
else {
    Write-Ok ('JDK         : ' + $jdkInfo.Path + ' (Java ' + $jdkInfo.Major + ')')
    Add-Result 'JDK' 'OK' ('Java ' + $jdkInfo.Major)
}
$JdkHome = $jdkInfo.Path

$AndroidSdk = Resolve-AndroidSdk
if (-not $AndroidSdk) {
    Write-Fail 'Android SDK not found. Pass -AndroidSdk "C:\path\to\sdk".'
    exit 1
}
Write-Ok ('Android SDK : ' + $AndroidSdk)

$FlutterBat = Join-Path $FlutterSdk 'bin\flutter.bat'
$BundledDart = Join-Path $FlutterSdk 'bin\cache\dart-sdk\bin\dart.exe'
$AvdManager = Join-Path $AndroidSdk 'cmdline-tools\latest\bin\avdmanager.bat'
$SdkManager = Join-Path $AndroidSdk 'cmdline-tools\latest\bin\sdkmanager.bat'
$Emulator = Join-Path $AndroidSdk 'emulator\emulator.exe'

$env:JAVA_HOME = $JdkHome
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk

Add-Result 'Tool discovery' 'OK' 'Flutter/JDK/Android SDK resolved'

# ---------------------------------------------------------------------------
# 2/11  adb / platform-tools
# ---------------------------------------------------------------------------
Write-Step '2/11  Repairing adb / platform-tools'
Repair-PlatformTools -SdkRoot $AndroidSdk | Out-Null

# A loose C:\platform-tools copy used to shadow the SDK one.
$strayTools = 'C:\platform-tools'
if (Test-Path -LiteralPath (Join-Path $strayTools 'adb.exe')) {
    if (Test-AdbHealthy (Join-Path $strayTools 'adb.exe')) {
        Write-Info 'Loose C:\platform-tools copy is healthy.'
    }
    elseif ($DryRun) {
        Write-Info 'Would replace the broken C:\platform-tools\adb.exe with the SDK one.'
    }
    else {
        Copy-Item -LiteralPath (Join-Path $AndroidSdk 'platform-tools\adb.exe') -Destination (Join-Path $strayTools 'adb.exe') -Force -ErrorAction SilentlyContinue
        Write-Ok 'Loose C:\platform-tools\adb.exe replaced with the working one.'
    }
}

# ---------------------------------------------------------------------------
# 3/11  Flutter global config
# ---------------------------------------------------------------------------
Write-Step '3/11  Repairing Flutter global config (.flutter_settings)'
$settingsPath = Join-Path $env:APPDATA '.flutter_settings'
$settings = @{}
if (Test-Path -LiteralPath $settingsPath) {
    $raw = Get-Content -LiteralPath $settingsPath -Raw
    if (-not $DryRun) { Backup-Text 'flutter-settings.json' $raw }
    if ($raw -and $raw.Trim()) {
        try {
            $parsed = $raw | ConvertFrom-Json
            foreach ($property in $parsed.PSObject.Properties) { $settings[$property.Name] = $property.Value }
        }
        catch {
            Write-Warn 'Existing .flutter_settings is not valid JSON; it will be rewritten.'
        }
    }
}

$oldJdk = $settings['jdk-dir']
$oldSdk = $settings['android-sdk']
$settings['jdk-dir'] = $JdkHome
$settings['android-sdk'] = $AndroidSdk

# Flutter happily stores `jdk-dir` as the java *executable*, which then makes
# Gradle fail with:
#   ERROR: JAVA_HOME is set to an invalid directory: ...\bin\java
if ($oldJdk -and $oldJdk -match '\\bin\\java(\.exe)?$') {
    Write-Warn ('jdk-dir points at the java executable, not the JDK home: ' + $oldJdk)
}

if ($oldJdk -eq $JdkHome -and $oldSdk -eq $AndroidSdk) {
    Write-Ok 'Flutter config already correct.'
    Add-Result 'Flutter config' 'OK' ('jdk-dir=' + $JdkHome)
}
elseif ($DryRun) {
    Write-Info ('Would set jdk-dir=' + $JdkHome + ' android-sdk=' + $AndroidSdk)
    Add-Result 'Flutter config' 'DRYRUN' 'would rewrite .flutter_settings'
}
else {
    if ($oldJdk -and $oldJdk -ne $JdkHome) { Write-Warn ('Replacing bad jdk-dir: ' + $oldJdk) }
    Write-TextFile $settingsPath ($settings | ConvertTo-Json -Depth 5)
    Write-Ok ('Wrote ' + $settingsPath)
    Add-Result 'Flutter config' 'FIXED' 'jdk-dir and android-sdk rewritten'
}

# ---------------------------------------------------------------------------
# 4/11  Environment variables
# ---------------------------------------------------------------------------
Write-Step '4/11  Fixing environment variables'

function Set-EnvValue {
    param([string]$Name, [string]$Value, [ValidateSet('Machine', 'User')][string]$Scope)
    $current = [Environment]::GetEnvironmentVariable($Name, $Scope)
    if ($current -eq $Value) {
        Write-Info ("$Scope $Name already = $Value")
        return
    }
    if ($DryRun) {
        Write-Info ("Would set $Scope $Name = $Value")
        return
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, $Scope)
    Write-Ok ("$Scope $Name = $Value")
}

foreach ($scope in @('Machine', 'User')) {
    Set-EnvValue -Name 'JAVA_HOME' -Value $JdkHome -Scope $scope
    Set-EnvValue -Name 'ANDROID_HOME' -Value $AndroidSdk -Scope $scope
    Set-EnvValue -Name 'ANDROID_SDK_ROOT' -Value $AndroidSdk -Scope $scope
}

# Remove placeholder junk that makes every JVM/Gradle launch fail.
$bogusMarkers = @('path/to/jdk', 'path\to\jdk', 'exit_with_errorlevel')
foreach ($scope in @('Machine', 'User')) {
    foreach ($name in @('_JAVA_OPTIONS', 'JAVA_TOOL_OPTIONS', 'JDK_JAVA_OPTIONS', 'DART_VM_OPTIONS')) {
        $value = [Environment]::GetEnvironmentVariable($name, $scope)
        if (-not $value) { continue }
        $isBogus = $false
        foreach ($marker in $bogusMarkers) { if ($value -like ('*' + $marker + '*')) { $isBogus = $true } }
        if ($isBogus) {
            if ($DryRun) { Write-Info ("Would remove bogus $scope $name=$value") }
            else {
                [Environment]::SetEnvironmentVariable($name, $null, $scope)
                Write-Ok ("Removed bogus $scope $name (was: $value)")
            }
        }
        else {
            Write-Warn ("$scope $name is set ($value). If Gradle behaves oddly, unset it.")
        }
    }
}

# ---------------------------------------------------------------------------
# 5/11  PATH
# ---------------------------------------------------------------------------
Write-Step '5/11  Repairing PATH order (Flutter must win over standalone Dart)'

function Get-PathState([ValidateSet('Machine', 'User')][string]$Scope) {
    $key = if ($Scope -eq 'Machine') { 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' } else { 'HKCU:\Environment' }
    $item = Get-Item -LiteralPath $key
    $kind = 'String'
    try { $kind = [string]$item.GetValueKind('Path') } catch { }
    $value = [string]$item.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    [pscustomobject]@{ Scope = $Scope; Key = $key; Kind = $kind; Value = $value }
}

function Set-PathState($State, [string]$Value) {
    if ($State.Kind -eq 'ExpandString') {
        Set-ItemProperty -LiteralPath $State.Key -Name 'Path' -Value $Value -Type ExpandString
    }
    else {
        Set-ItemProperty -LiteralPath $State.Key -Name 'Path' -Value $Value -Type String
    }
}

function Split-PathList([string]$Value) {
    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Get-Normalized([string]$Entry) {
    return $Entry.Trim().TrimEnd('\').ToLowerInvariant()
}

$pathPrefix = @(
    (Join-Path $FlutterSdk 'bin'),
    (Join-Path $JdkHome 'bin'),
    (Join-Path $AndroidSdk 'platform-tools'),
    (Join-Path $AndroidSdk 'emulator'),
    (Join-Path $AndroidSdk 'cmdline-tools\latest\bin')
) | Where-Object { Test-Path -LiteralPath $_ }

$prefixNorm = @($pathPrefix | ForEach-Object { Get-Normalized $_ })

$machineState = Get-PathState -Scope 'Machine'
$userState = Get-PathState -Scope 'User'

$machineKept = New-Object System.Collections.Generic.List[string]
$seen = New-Object System.Collections.Generic.HashSet[string]
foreach ($entry in (Split-PathList $machineState.Value)) {
    $norm = Get-Normalized $entry
    if ($prefixNorm -contains $norm) { continue }
    if ($seen.Add($norm)) { $machineKept.Add($entry) }
}
$newMachine = (@($pathPrefix) + @($machineKept)) -join ';'

$userKept = New-Object System.Collections.Generic.List[string]
$seenUser = New-Object System.Collections.Generic.HashSet[string]
foreach ($entry in (Split-PathList $userState.Value)) {
    $norm = Get-Normalized $entry
    if ($prefixNorm -contains $norm) { continue }
    if ($seenUser.Add($norm)) { $userKept.Add($entry) }
}
$newUser = ($userKept) -join ';'

$machineChanged = ($newMachine -ne $machineState.Value)
$userChanged = ($newUser -ne $userState.Value)

if ($machineChanged) {
    if ($DryRun) { Write-Info 'Would rewrite machine PATH (Flutter/JDK/Android SDK first, duplicates removed)' }
    else {
        Set-PathState -State $machineState -Value $newMachine
        Write-Ok 'Machine PATH rewritten (prefix first, duplicates removed)'
    }
}
else { Write-Ok 'Machine PATH already correct.' }

if ($userChanged) {
    if ($DryRun) { Write-Info 'Would remove duplicate tool entries from user PATH' }
    else {
        Set-PathState -State $userState -Value $newUser
        Write-Ok 'User PATH deduplicated'
    }
}
else { Write-Ok 'User PATH already correct.' }

$env:Path = ((@($pathPrefix) + (Split-PathList $env:Path)) | Where-Object { $_ } | Select-Object -Unique) -join ';'

if ($machineChanged -or $userChanged) {
    if ($DryRun) { Add-Result 'PATH' 'DRYRUN' 'would reorder machine PATH / dedupe user PATH' }
    else { Add-Result 'PATH' 'FIXED' 'Flutter bin ordered before standalone Dart' }
}
else {
    Add-Result 'PATH' 'OK' 'No change required'
}

if (-not $DryRun) {
    try {
        if (-not ('Win32.NativeMethods' -as [type])) {
            Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $resultHandle = [UIntPtr]::Zero
        [void][Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$resultHandle)
        Write-Ok 'Broadcast WM_SETTINGCHANGE (new terminals will see the values)'
    }
    catch {
        Write-Warn ('Could not broadcast WM_SETTINGCHANGE: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 6/11  Long paths
# ---------------------------------------------------------------------------
Write-Step '6/11  Enabling Windows long-path support'
$fileSystemKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
try {
    $item = Get-ItemProperty -LiteralPath $fileSystemKey -ErrorAction SilentlyContinue
    $currentLongPaths = 0
    if ($item -and $item.PSObject.Properties['LongPathsEnabled']) { $currentLongPaths = $item.LongPathsEnabled }

    if ($currentLongPaths -eq 1) {
        Write-Ok 'LongPathsEnabled already = 1'
        Add-Result 'Long paths' 'OK' 'Already enabled'
    }
    elseif ($DryRun) {
        Write-Info 'Would set LongPathsEnabled = 1'
        Add-Result 'Long paths' 'DRYRUN' 'would enable'
    }
    else {
        Set-ItemProperty -LiteralPath $fileSystemKey -Name LongPathsEnabled -Value 1 -Type DWord
        Write-Ok 'LongPathsEnabled = 1'
        Add-Result 'Long paths' 'FIXED' 'Enabled'
    }
}
catch {
    Write-Fail ('Could not set LongPathsEnabled: ' + $_.Exception.Message)
    Add-Result 'Long paths' 'FAILED' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 7/11  Filesystem filter driver (delayed / zero-byte compiler output)
# ---------------------------------------------------------------------------
Write-Step '7/11  Checking filesystem filters (compiler output corruption)'

$filterList = @()
if ($isAdmin) {
    $filterResult = Invoke-Capture -FilePath 'fltmc.exe' -ArgumentList @('filters')
    $filterList = @($filterResult.Output | ForEach-Object { $_.ToString() })
}
else {
    Write-Info 'Not elevated: skipping filter driver inspection.'
}

$wiseFilter = $filterList | Where-Object { $_ -match '^\s*WiseFS\s' } | Select-Object -First 1
if ($wiseFilter) {
    Write-Warn 'WiseFS filter driver is loaded (left over from Wise Care 360).'
    Write-Warn 'It delays/zeroes freshly written compiler output, which makes'
    Write-Warn 'pub, flutter test and gradle fail with "compiler exited unexpectedly".'

    if ($DryRun) {
        Write-Info 'Would unload WiseFS for this boot (use -DisableWiseFilter).'
        Add-Result 'File filter' 'DRYRUN' 'WiseFS loaded'
    }
    elseif ($DisableWiseFilter) {
        $unload = Invoke-Capture -FilePath 'fltmc.exe' -ArgumentList @('unload', 'WiseFS')
        if ($unload.ExitCode -eq 0) {
            Write-Ok 'WiseFS unloaded for this boot.'
            Add-Result 'File filter' 'FIXED' 'WiseFS unloaded'
        }
        else {
            Write-Warn ('Could not unload WiseFS: ' + (Get-CaptureText $unload))
            Write-Warn 'Uninstall Wise Care 360, then reboot.'
            Add-Result 'File filter' 'WARN' 'WiseFS still loaded'
        }
    }
    else {
        Write-Warn 'Re-run with -DisableWiseFilter, or uninstall Wise Care 360 and reboot.'
        Add-Result 'File filter' 'WARN' 'WiseFS loaded (use -DisableWiseFilter)'
    }
}
else {
    Write-Ok 'No WiseFS filter driver loaded.'
    Add-Result 'File filter' 'OK' 'no WiseFS'
}

# Smoke-test the Dart compiler: it must produce a non-zero kernel file.
if (Test-Path -LiteralPath $BundledDart) {
    $smokeDir = Join-Path $ProjectRoot '.dart-smoke'
    if ($DryRun) {
        Write-Info 'Would compile a smoke-test kernel file with the bundled Dart.'
        Add-Result 'Dart compiler' 'DRYRUN' 'smoke test skipped'
    }
    else {
        try {
            if (Test-Path -LiteralPath $smokeDir) { Remove-Item -LiteralPath $smokeDir -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $smokeDir -Force | Out-Null
            Write-TextFile (Join-Path $smokeDir 'smoke.dart') 'void main() { print("ok"); }'

            $previous = Get-Location
            Set-Location $smokeDir
            try {
                $compile = Invoke-Capture -FilePath $BundledDart -ArgumentList @('compile', 'kernel', 'smoke.dart', '-o', 'smoke.dill')
            }
            finally { Set-Location $previous }

            $size = Wait-FileReady -Path (Join-Path $smokeDir 'smoke.dill') -TimeoutSeconds 25
            if ($compile.ExitCode -eq 0 -and $size -gt 100000) {
                Write-Ok ('Dart compiler OK (kernel {0:N0} bytes)' -f $size)
                Add-Result 'Dart compiler' 'OK' 'kernel compiled'
            }
            else {
                Write-Fail ('Dart compiler produced ' + $size + ' bytes (exit ' + $compile.ExitCode + ').')
                Write-Fail 'A filesystem filter or antivirus is eating compiler output.'
                Add-Result 'Dart compiler' 'FAILED' 'zero-byte kernel'
            }
        }
        catch {
            Write-Warn ('Dart smoke test failed: ' + $_.Exception.Message)
            Add-Result 'Dart compiler' 'WARN' $_.Exception.Message
        }
        finally {
            Remove-Item -LiteralPath $smokeDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 8/11  FVM project wiring
# ---------------------------------------------------------------------------
Write-Step '8/11  Wiring the project to FVM'
$appRoot = Join-Path $ProjectRoot 'app'
$pubspecPath = Join-Path $appRoot 'pubspec.yaml'
$projectFound = Test-Path -LiteralPath $pubspecPath

if (-not $projectFound) {
    Write-Warn ('No app\pubspec.yaml under ' + $ProjectRoot + ' - skipping project repairs.')
    Add-Result 'Project' 'SKIPPED' 'pubspec.yaml not found'
}
else {
    Set-FvmProject -AppRoot $appRoot -SdkPath $FlutterSdk

    $fvmrcPath = Join-Path $appRoot '.fvmrc'
    $ignorePath = Join-Path $appRoot '.gitignore'
    if (-not $DryRun -and (Test-Path -LiteralPath $ignorePath)) {
        $ignore = Get-Content -LiteralPath $ignorePath -Raw
        if ($ignore -notmatch '(?m)^\s*\.fvm/') {
            Backup-Text 'gitignore' $ignore
            Write-TextFile $ignorePath ($ignore.TrimEnd() + "`r`n.fvm/flutter_sdk`r`n")
            Write-Info 'Added .fvm/flutter_sdk to .gitignore'
        }
    }
}

# ---------------------------------------------------------------------------
# 9/11  Project configuration
# ---------------------------------------------------------------------------
Write-Step '9/11  Repairing project configuration'

if ($projectFound) {
    $pubspecOriginal = [System.IO.File]::ReadAllText($pubspecPath)
    $pubspecUpdated = $pubspecOriginal

    # permission_handler 13 -> permission_handler_android 14.1.1 needs AGP 9 /
    # Kotlin 2.3 / compileSdk 37, none of which Flutter 3.35 provides.
    $pubspecUpdated = [regex]::Replace(
        $pubspecUpdated,
        '(?m)^(\s*)permission_handler:\s*\^1[23]\.[^\r\n]*$',
        '${1}permission_handler: ^11.4.0'
    )
    # shared_preferences 2.5.6 requires Dart 3.11; pin to the 3.9-compatible release.
    $pubspecUpdated = [regex]::Replace(
        $pubspecUpdated,
        '(?m)^(\s*)shared_preferences:\s*\^2\.5\.6[^\r\n]*$',
        '${1}shared_preferences: ^2.5.5'
    )

    if ($pubspecUpdated -ne $pubspecOriginal) {
        if ($DryRun) {
            Write-Info 'Would pin permission_handler/shared_preferences in pubspec.yaml'
            Add-Result 'pubspec.yaml' 'DRYRUN' 'version pins would change'
        }
        else {
            Backup-Text 'pubspec.yaml' $pubspecOriginal
            Write-TextFile $pubspecPath $pubspecUpdated
            Write-Ok 'Pinned compatible plugin versions in pubspec.yaml'
            Add-Result 'pubspec.yaml' 'FIXED' 'permission_handler ^11.4.0, shared_preferences ^2.5.5'
        }
    }
    else {
        Write-Ok 'pubspec.yaml already has compatible pins.'
        Add-Result 'pubspec.yaml' 'OK' 'No change required'
    }

    $localPropsPath = Join-Path $appRoot 'android\local.properties'
    if (Test-Path -LiteralPath $localPropsPath) {
        $localOriginal = [System.IO.File]::ReadAllText($localPropsPath)
        $sdkEscaped = $AndroidSdk.Replace('\', '\\')
        $flutterEscaped = $FlutterSdk.Replace('\', '\\')
        $localUpdated = $localOriginal

        if ($localUpdated -match '(?m)^\s*sdk\.dir\s*=') {
            $localUpdated = [regex]::Replace($localUpdated, '(?m)^\s*sdk\.dir\s*=[^\r\n]*', ('sdk.dir=' + $sdkEscaped))
        }
        else {
            $localUpdated = $localUpdated.TrimEnd() + "`r`nsdk.dir=" + $sdkEscaped + "`r`n"
        }
        if ($localUpdated -match '(?m)^\s*flutter\.sdk\s*=') {
            $localUpdated = [regex]::Replace($localUpdated, '(?m)^\s*flutter\.sdk\s*=[^\r\n]*', ('flutter.sdk=' + $flutterEscaped))
        }
        else {
            $localUpdated = $localUpdated.TrimEnd() + "`r`nflutter.sdk=" + $flutterEscaped + "`r`n"
        }

        if ($localUpdated -ne $localOriginal) {
            if ($DryRun) {
                Write-Info 'Would update android\local.properties'
                Add-Result 'local.properties' 'DRYRUN' 'paths would be corrected'
            }
            else {
                Backup-Text 'local.properties' $localOriginal
                Write-TextFile $localPropsPath $localUpdated
                Write-Ok 'android\local.properties points at the detected SDKs'
                Add-Result 'local.properties' 'FIXED' 'sdk.dir / flutter.sdk corrected'
            }
        }
        else {
            Write-Ok 'android\local.properties already correct.'
            Add-Result 'local.properties' 'OK' 'No change required'
        }
    }

    # Gradle daemons hold the JDK that was used to start them. If the JDK just
    # changed, the next build fails until the old daemon is gone.
    $gradlew = Join-Path $appRoot 'android\gradlew.bat'
    if (-not $DryRun -and (Test-Path -LiteralPath $gradlew)) {
        Invoke-Capture -FilePath $gradlew -ArgumentList @('--stop') | Out-Null
    }
}

# ---------------------------------------------------------------------------
# 10/11  Clean + dependencies
# ---------------------------------------------------------------------------
if ($DryRun) {
    Write-Step '10/11  Cleaning / package resolution'
    Write-Info 'Skipped (dry run)'
}
elseif ($projectFound) {
    Write-Step '10/11  Cleaning stale build output and resolving packages'

    foreach ($relative in @('build', '.dart_tool', 'android\.gradle', 'android\build', 'android\app\build')) {
        $target = Join-Path $appRoot $relative
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            Write-Info ('Removed ' + $relative)
        }
    }

    try {
        Push-Location $appRoot
        try {
            Invoke-Native -FilePath $FlutterBat -ArgumentList @('pub', 'get') | Out-Null
            Write-Ok 'flutter pub get'
            Invoke-Native -FilePath $FlutterBat -ArgumentList @('precache', '--android') | Out-Null
            Write-Ok 'flutter precache --android'
        }
        finally { Pop-Location }
        Add-Result 'Dependencies' 'FIXED' 'pub get + precache completed'
    }
    catch {
        Write-Fail ('Dependency resolution failed: ' + $_.Exception.Message)
        Add-Result 'Dependencies' 'FAILED' $_.Exception.Message
    }

    if ($RepairCache) {
        Write-Info 'flutter pub cache repair (slow)'
        try {
            Push-Location $appRoot
            try { Invoke-Native -FilePath $FlutterBat -ArgumentList @('pub', 'cache', 'repair') | Out-Null }
            finally { Pop-Location }
            Write-Ok 'Pub cache repaired'
        }
        catch {
            Write-Fail ('pub cache repair failed: ' + $_.Exception.Message)
        }
    }
}
else {
    Write-Step '10/11  Cleaning / package resolution'
    Write-Info 'Skipped (no project)'
}

# ---------------------------------------------------------------------------
# 11/11  Emulator + verification
# ---------------------------------------------------------------------------
Write-Step '11/11  Emulator and verification'

if (-not $CreateEmulator) {
    Write-Info 'Emulator: skipped (use -CreateEmulator).'
    Add-Result 'Emulator' 'SKIPPED' 'Use -CreateEmulator'
}
elseif ($DryRun) {
    Write-Info 'Would create/verify the opensms_gateway AVD'
    Add-Result 'Emulator' 'DRYRUN' 'would create AVD'
}
else {
    try {
        $existingAvds = @()
        if (Test-Path -LiteralPath $Emulator) {
            $avdResult = Invoke-Capture -FilePath $Emulator -ArgumentList @('-list-avds')
            $existingAvds = @($avdResult.Output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })
        }

        if ($existingAvds -contains 'opensms_gateway') {
            Write-Ok 'AVD opensms_gateway already exists.'
            Add-Result 'Emulator' 'OK' 'AVD present'
        }
        elseif (-not (Test-Path -LiteralPath $AvdManager)) {
            Write-Fail ('avdmanager.bat missing at ' + $AvdManager)
            Add-Result 'Emulator' 'FAILED' 'avdmanager not installed'
        }
        else {
            $image = Get-ChildItem -LiteralPath (Join-Path $AndroidSdk 'system-images') -Recurse -Depth 2 -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('x86_64', 'arm64-v8a') } |
                Select-Object -First 1

            if (-not $image) {
                Write-Fail 'No system image installed. Run: sdkmanager "system-images;android-35;google_apis;x86_64"'
                Add-Result 'Emulator' 'FAILED' 'No system image'
            }
            else {
                $relative = $image.FullName.Substring((Join-Path $AndroidSdk 'system-images').Length).TrimStart('\')
                $package = 'system-images;' + ($relative -replace '\\', ';')
                Write-Info ('Creating AVD from ' + $package)

                $created = $false
                $previous = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    foreach ($device in @('pixel_6', 'pixel')) {
                        'no' | & $AvdManager create avd -n opensms_gateway -k $package -d $device --force 2>&1 |
                            ForEach-Object { Write-Host ('        ' + $_) -ForegroundColor DarkGray }
                        if ($LASTEXITCODE -eq 0) { $created = $true; break }
                    }
                }
                finally { $ErrorActionPreference = $previous }

                if ($created) {
                    Write-Ok 'AVD opensms_gateway created. Launch: flutter emulators --launch opensms_gateway'
                    Add-Result 'Emulator' 'FIXED' ('Created from ' + $package)
                }
                else {
                    Write-Fail 'avdmanager could not create the AVD.'
                    Add-Result 'Emulator' 'FAILED' 'avdmanager error'
                }
            }
        }
    }
    catch {
        Write-Fail ('Emulator setup failed: ' + $_.Exception.Message)
        Add-Result 'Emulator' 'FAILED' $_.Exception.Message
    }
}

if (-not $DryRun) {
    # dart on PATH must resolve inside the Flutter SDK.
    $dartCommand = Get-Command dart -ErrorAction SilentlyContinue
    if ($dartCommand) {
        $dartResult = Invoke-Capture -FilePath $dartCommand.Source -ArgumentList @('--version')
        $dartVersion = Get-CaptureText $dartResult
        Write-Info ('dart on PATH : ' + $dartCommand.Source)
        Write-Info ('             : ' + $dartVersion)
        if ($dartCommand.Source -notlike (Join-Path $FlutterSdk 'bin\*')) {
            Write-Warn 'dart still resolves outside the Flutter SDK in THIS window. Open a new terminal.'
        }
    }
    else {
        Write-Warn 'dart is not on PATH. Open a new terminal after this script.'
    }

    # Connected Android devices, using the SDK adb.
    $adbPath = Join-Path $AndroidSdk 'platform-tools\adb.exe'
    if (Test-Path -LiteralPath $adbPath) {
        $devices = Invoke-Capture -FilePath $adbPath -ArgumentList @('devices')
        $deviceLines = @($devices.Output | ForEach-Object { $_.ToString() } | Where-Object { $_ -match '\sdevice$' })
        if ($deviceLines.Count -gt 0) {
            Write-Ok ('Android device(s): ' + ($deviceLines -join '; '))
        }
        else {
            Write-Warn 'No Android device attached. Connect a phone with USB debugging, or run with -CreateEmulator.'
        }
    }

    try {
        $doctorFile = Join-Path $script:BackupDir 'flutter-doctor.txt'
        $doctorResult = Invoke-Capture -FilePath $FlutterBat -ArgumentList @('doctor', '-v')
        Write-TextFile $doctorFile (Get-CaptureText $doctorResult)
        Write-Ok ('flutter doctor saved to ' + $doctorFile)
    }
    catch {
        Write-Warn ('flutter doctor failed: ' + $_.Exception.Message)
    }

    if ($projectFound) {
        try {
            Push-Location $appRoot
            try {
                Invoke-Native -FilePath $FlutterBat -ArgumentList @('analyze') | Out-Null
                Write-Ok 'flutter analyze: no issues'
                Add-Result 'Analyze' 'OK' 'No analyzer issues'
            }
            finally { Pop-Location }
        }
        catch {
            Write-Fail 'flutter analyze reported problems (see output above).'
            Add-Result 'Analyze' 'FAILED' 'Analyzer issues'
        }

        if ($RunTests) {
            try {
                Push-Location $appRoot
                try {
                    Invoke-Native -FilePath $FlutterBat -ArgumentList @('test') | Out-Null
                    Write-Ok 'flutter test passed'
                    Add-Result 'Tests' 'OK' 'Test suite passed'
                }
                finally { Pop-Location }
            }
            catch {
                Write-Fail 'flutter test failed. If it says "Dart compiler exited unexpectedly", re-run with -DisableWiseFilter.'
                Add-Result 'Tests' 'FAILED' 'Test compiler/toolchain'
            }
        }

        if (-not $SkipBuild) {
            Write-Info 'Building debug APK (first run may download Gradle dependencies)...'
            try {
                Push-Location $appRoot
                try {
                    Invoke-Native -FilePath $FlutterBat -ArgumentList @('build', 'apk', '--debug') | Out-Null
                }
                finally { Pop-Location }
                $apk = Join-Path $appRoot 'build\app\outputs\flutter-apk\app-debug.apk'
                if (Test-Path -LiteralPath $apk) {
                    Write-Ok ('APK: ' + $apk)
                    Add-Result 'APK build' 'OK' $apk
                }
                else {
                    Write-Warn 'Build reported success but app-debug.apk was not found.'
                    Add-Result 'APK build' 'WARN' 'APK not found'
                }
            }
            catch {
                Write-Fail 'APK build failed (see Gradle output above).'
                Add-Result 'APK build' 'FAILED' 'Gradle build error'
            }
        }
        else {
            Write-Info 'APK build skipped (-SkipBuild).'
        }
    }
}
else {
    Write-Info 'Verification commands skipped in dry-run mode.'
}

# ---------------------------------------------------------------------------
# Restore script
# ---------------------------------------------------------------------------
if (-not $DryRun) {
    $restore = @'
# Restores the environment captured before fix-dev-environment.ps1 ran.
# Run elevated:  powershell -NoProfile -ExecutionPolicy Bypass -File .\restore.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$machinePath = Get-Content -LiteralPath (Join-Path $here 'path-machine.txt') -Raw
$userPath = Get-Content -LiteralPath (Join-Path $here 'path-user.txt') -Raw
Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name Path -Value $machinePath -Type ExpandString
Set-ItemProperty -LiteralPath 'HKCU:\Environment' -Name Path -Value $userPath -Type ExpandString

$settings = Join-Path $here 'flutter-settings.json'
if (Test-Path -LiteralPath $settings) {
    Copy-Item -LiteralPath $settings -Destination (Join-Path $env:APPDATA '.flutter_settings') -Force
}
Write-Host 'Environment restored. Open a new terminal.' -ForegroundColor Green
'@
    Write-TextFile (Join-Path $script:BackupDir 'restore.ps1') $restore
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Summary' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
$script:Results | Format-Table -AutoSize -Wrap | Out-String | Write-Host

if (-not $DryRun) {
    Write-Host (' Backups / logs: ' + $script:BackupDir) -ForegroundColor Gray
    Write-Host (' Restore with  : ' + (Join-Path $script:BackupDir 'restore.ps1')) -ForegroundColor Gray
}

Write-Host ''
Write-Host ' Next steps:' -ForegroundColor White
Write-Host '   1. CLOSE this window and open a NEW PowerShell (env changes only apply to new processes).'
Write-Host '   2. cd app'
Write-Host '   3. fvm flutter devices        (or: .\.fvm\flutter_sdk\bin\flutter devices)'
Write-Host '   4. Connect a phone with USB debugging, or: flutter emulators --launch opensms_gateway'
Write-Host '   5. fvm flutter run -d <device-id>'
Write-Host ''

if ($script:Failures -gt 0) {
    Write-Host ('Finished with ' + $script:Failures + ' failure(s), ' + $script:Warnings + ' warning(s). Review the log above.') -ForegroundColor Red
    exit 1
}

if ($script:Warnings -gt 0) {
    Write-Host ('All required checks passed with ' + $script:Warnings + ' warning(s).') -ForegroundColor Yellow
    exit 0
}

Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
