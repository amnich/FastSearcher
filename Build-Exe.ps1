#Requires -Version 5.1
<#
.SYNOPSIS
    Compiles FastSearcher.ps1 into a standalone executable (.EXE) using the PS2EXE module.

.DESCRIPTION
    Verifies the presence of the ps2exe module (installs from PSGallery if needed) and produces
    a windowed application without console (-NoConsole) in Single-Threaded Apartment (-STA) mode.
    After compilation, ensures language.json and config.json are present next to the output
    executable so the multi-language UI (EN/DE/PL) and saved settings work at runtime.

.PARAMETER OutputFile
    Path to the output executable (.EXE). Defaults to FastSearcher.exe next to this script.

.PARAMETER IconFile
    Path to a .ico icon file (optional).

.EXAMPLE
    .\Build-Exe.ps1
    Compiles FastSearcher.exe in the current folder.

.NOTES
    Encoding: UTF-8 with BOM
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputFile,

    [Parameter(Mandatory = $false)]
    [string]$IconFile = "D:\Skrypty\Mnich_Adam_Skrypty\!Helper\Logo_AM6.ico"
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
    Version     = '1.1.0.0'
    NoError     = $true
    NoOutput    = $true
}

if (-not [string]::IsNullOrWhiteSpace($IconFile) -and (Test-Path $IconFile)) {
    $CompileParams['IconFile'] = $IconFile
    Write-Host "Icon file   : $IconFile" -ForegroundColor White
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
foreach ($extraFile in @('language.json', 'config.json')) {
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
