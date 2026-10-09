#Requires -Version 5.1
<#
.SYNOPSIS
    Compiles FastSearcher.ps1 into a standalone executable (.EXE) using the PS2EXE module.

.DESCRIPTION
    Verifies the presence of the ps2exe module (installs from PSGallery if needed) and produces
    a windowed application without console (-NoConsole) in Single-Threaded Apartment (-STA) mode.
    After compilation, ensures language.json is present next to the output executable and builds
    an Inno Setup installer using the same executable version and icon. Signing is optional.

.PARAMETER OutputFile
    Path to the output executable (.EXE). Defaults to FastSearcher.exe next to this script.

.PARAMETER IconFile
    Path to a .ico icon file (optional).

.PARAMETER NoInstaller
    Skip building the Inno Setup installer. This is useful when only the EXE is required.

.PARAMETER SignInstaller
    Sign and timestamp the installer. Requires SignTool and a valid code-signing certificate.

.EXAMPLE
    .\Build-Exe.ps1
    Compiles FastSearcher.exe and creates a signed installer in dist\installer.

.EXAMPLE
    .\Build-Exe.ps1 -NoInstaller
    Compiles only FastSearcher.exe.

.EXAMPLE
    .\Build-Exe.ps1 -SignInstaller
    Compiles the EXE and creates a signed installer.

.NOTES
    Encoding: UTF-8 with BOM
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputFile,

    [Parameter(Mandatory = $false)]
    [string]$IconFile = "D:\Skrypty\Mnich_Adam_Skrypty\!Helper\Logo_AM6.ico",

    [Parameter(Mandatory = $false)]
    [switch]$NoInstaller,

    [Parameter(Mandatory = $false)]
    [switch]$SignInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$InputScript = Join-Path $ScriptDir 'FastSearcher.ps1'

if (-not $OutputFile) {
    $OutputFile = Join-Path $ScriptDir 'FastSearcher.exe'
}

$AppTitle = 'FastSearcher - Fast Search Tool'
$AppDesc = 'Ultra-fast multi-threaded search tool inside files with multi-language UI (EN/DE/PL)'

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " PS2EXE COMPILATION: FastSearcher" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Close any running instance of the output executable to avoid file lock
$targetProcName = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
$runningProc = Get-Process -Name $targetProcName -ErrorAction SilentlyContinue
if ($runningProc) {
    Write-Host "Stopping running instance of $targetProcName (PID: $($runningProc.Id))..." -ForegroundColor Yellow
    $runningProc | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
}

# 1. Verify PS2EXE module
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "ps2exe module not found. Installing from PSGallery (CurrentUser)..." -ForegroundColor Yellow
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
    }
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
    Write-Host "ps2exe module installed successfully." -ForegroundColor Green
}

Import-Module -Name ps2exe -Force

# 2. Validate source script
if (-not (Test-Path $InputScript)) {
    throw "Source file does not exist: $InputScript"
}

Write-Host "Source file : $InputScript" -ForegroundColor White
Write-Host "Output file : $OutputFile" -ForegroundColor White

#get version from exe file if exists and bump build number
$Currentversion = [version]"0.0.1"
if (Test-Path -LiteralPath $OutputFile) {
    try {
        $fileVersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($OutputFile)
        $Currentversion = [version]$fileVersionInfo.FileVersion
        #increment build number by 1
        $Currentversion = [version]::new($Currentversion.Major, $Currentversion.Minor, $Currentversion.Build + 1)
    } catch {
        Write-Warning "Failed to retrieve version from existing executable. Defaulting to 0.0.1"
    }
}


# 3. PS2EXE compilation parameters
$CompileParams = @{
    InputFile   = $InputScript
    OutputFile  = $OutputFile
    NoConsole   = $true
    STA         = $true
    Title       = $AppTitle
    Description = $AppDesc
    Company     = 'Adam Mnich'
    Product     = 'FastSearcher'
    Copyright   = 'Copyright (c) 2026 Adam Mnich'
    Version     = $Currentversion.ToString()
    NoError     = $true
    NoOutput    = $true
}

$resolvedIconFile = $null
if (-not [string]::IsNullOrWhiteSpace($IconFile) -and (Test-Path -LiteralPath $IconFile -PathType Leaf)) {
    $resolvedIconFile = (Resolve-Path -LiteralPath $IconFile).Path
} else {
    $sharedScriptsRoot = Join-Path (Split-Path -Parent $ScriptDir) 'Mnich_Adam_Skrypty'
    $fallbackIcons = @(
        (Join-Path $sharedScriptsRoot '!Helper\Logo_AM6.ico')
    )
    $resolvedIconFile = $fallbackIcons |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}

if ($resolvedIconFile) {
    $CompileParams['IconFile'] = $resolvedIconFile
    Write-Host "Icon file   : $resolvedIconFile" -ForegroundColor White
} else {
    Write-Warning 'No application icon was found; the EXE will be built without a custom icon.'
}

# 4. Invoke compiler
Write-Host "`nStarting compilation..." -ForegroundColor Yellow
Invoke-PS2EXE @CompileParams

if (-not (Test-Path $OutputFile)) {
    throw "Compilation completed, but output file $OutputFile was not found."
}

$item = Get-Item $OutputFile
$sizeKb = [math]::Round($item.Length / 1KB, 1)
Write-Host "`n[SUCCESS] Executable created successfully!" -ForegroundColor Green
Write-Host "Path : $($item.FullName)" -ForegroundColor Green
Write-Host "Size : $sizeKb KB" -ForegroundColor Green

# 5. Ensure language.json and config.json are available next to the output executable
# (FastSearcher.ps1 resolves both files relative to its own folder at runtime)
$OutputDir = Split-Path -Parent $item.FullName
foreach ($extraFile in @('language.json')) {
    $sourceFile = Join-Path $ScriptDir $extraFile
    $destFile = Join-Path $OutputDir $extraFile
    if ((Test-Path $sourceFile) -and ($sourceFile -ne $destFile) -and -not (Test-Path $destFile)) {
        Copy-Item -LiteralPath $sourceFile -Destination $destFile -Force
        Write-Host "Copied $extraFile to output folder." -ForegroundColor Green
    }
    elseif (-not (Test-Path $sourceFile) -and $extraFile -eq 'language.json') {
        Write-Warning "language.json not found next to the source script; the compiled EXE will fall back to built-in English strings."
    }
}

# 6. Build the installer with the exact EXE, version, and icon produced above.
if (-not $NoInstaller) {
    if (-not $resolvedIconFile) {
        throw 'Cannot build the installer without an icon. Specify -IconFile or use -NoInstaller to build only the EXE.'
    }

    $installerBuildScript = Join-Path $ScriptDir 'installer\Build-Installer.ps1'
    if (-not (Test-Path -LiteralPath $installerBuildScript -PathType Leaf)) {
        throw "Installer build script was not found: $installerBuildScript"
    }

    Write-Host "`nBuilding installer for version $($Currentversion.ToString())..." -ForegroundColor Cyan
    $installerArguments = @{
        ExePath    = $item.FullName
        AppVersion = $Currentversion.ToString()
        IconFile   = $resolvedIconFile
    }
    if ($SignInstaller) {
        $installerArguments['Sign'] = $true
    }
    & $installerBuildScript @installerArguments
}
