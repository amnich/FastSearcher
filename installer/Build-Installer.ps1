#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$CompilerPath,

    [Parameter()]
    [string]$SignToolPath = 'C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe',

    [Parameter()]
    [string]$ExePath,

    [Parameter()]
    [string]$AppVersion,

    [Parameter()]
    [string]$IconFile,

    [Parameter()]
    [switch]$Sign
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installerDir = $PSScriptRoot
$projectRoot = Split-Path -Parent $installerDir
$issPath = Join-Path $installerDir 'FastSearcher.iss'
$defaultExePath = Join-Path $projectRoot 'FastSearcher.exe'
$defaultIconPath = Join-Path (Split-Path -Parent $projectRoot) 'Mnich_Adam_Skrypty\!Helper\Logo_AM6.ico'

if (-not $ExePath) { $ExePath = $defaultExePath }
if (-not $IconFile) { $IconFile = $defaultIconPath }
if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    throw "Application executable was not found: $ExePath"
}
if (-not (Test-Path -LiteralPath $IconFile -PathType Leaf)) {
    throw "Installer icon was not found: $IconFile"
}
$ExePath = (Resolve-Path -LiteralPath $ExePath).Path
$IconFile = (Resolve-Path -LiteralPath $IconFile).Path

$requiredFiles = @(
    (Join-Path $projectRoot 'language.json'),
    (Join-Path $projectRoot 'README.md'),
    (Join-Path $projectRoot 'LICENSE'),
    $issPath
)
foreach ($path in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required installer input was not found: $path"
    }
}

if (-not $CompilerPath) {
    $compilerCommand = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($compilerCommand) {
        $CompilerPath = $compilerCommand.Source
    } else {
        $compilerCandidates = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
        $CompilerPath = $compilerCandidates | Select-Object -First 1
    }
}

if (-not $CompilerPath -or -not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
    throw 'Inno Setup 6 compiler (ISCC.exe) was not found. Install Inno Setup 6 or pass -CompilerPath.'
}
$signingCert = $null
if ($Sign) {
    if (-not (Test-Path -LiteralPath $SignToolPath -PathType Leaf)) {
        throw "SignTool was not found: $SignToolPath. Pass -SignToolPath to specify another location."
    }

    $signingCert = Get-ChildItem cert:\CurrentUser\my -ErrorAction SilentlyContinue |
        Where-Object {
            $_.EnhancedKeyUsageList -match '1.3.6.1.5.5.7.3.3' -and
            $_.HasPrivateKey -and
            $_.NotAfter -gt (Get-Date)
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if (-not $signingCert) {
        throw 'No current code-signing certificate with a private key was found in Cert:\CurrentUser\My.'
    }
}

if (-not $AppVersion) {
    $AppVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ExePath).FileVersion
}
if ($AppVersion -notmatch '^\d+(\.\d+){1,3}$') {
    throw "Invalid installer version: '$AppVersion'."
}

$outputDir = Join-Path $projectRoot 'dist\installer'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$compilerArguments = @(
    "/DAppVersion=$AppVersion"
    $issPath
)

Write-Host "Compiling FastSearcher installer version $AppVersion..." -ForegroundColor Cyan
Write-Host "Application icon: $IconFile" -ForegroundColor Gray
$oldExePath = [Environment]::GetEnvironmentVariable('FASTSEARCHER_EXE_PATH', 'Process')
$oldIconPath = [Environment]::GetEnvironmentVariable('FASTSEARCHER_ICON_PATH', 'Process')
try {
    [Environment]::SetEnvironmentVariable('FASTSEARCHER_EXE_PATH', $ExePath, 'Process')
    [Environment]::SetEnvironmentVariable('FASTSEARCHER_ICON_PATH', $IconFile, 'Process')
    & $CompilerPath @compilerArguments
    $compileExitCode = $LASTEXITCODE
} finally {
    [Environment]::SetEnvironmentVariable('FASTSEARCHER_EXE_PATH', $oldExePath, 'Process')
    [Environment]::SetEnvironmentVariable('FASTSEARCHER_ICON_PATH', $oldIconPath, 'Process')
}
if ($compileExitCode -ne 0) {
    throw "Inno Setup compilation failed with exit code $compileExitCode"
}

$installerPath = Join-Path $outputDir "FastSearcher-Setup-$AppVersion.exe"
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Installer compilation completed but output was not found: $installerPath"
}

if ($Sign) {
    Write-Host "Signing installer with certificate: $($signingCert.Subject)..." -ForegroundColor Yellow
    & $SignToolPath sign /sha1 $signingCert.Thumbprint /tr 'http://timestamp.sectigo.com' /td SHA256 /fd SHA256 $installerPath
    if ($LASTEXITCODE -ne 0) {
        throw "SignTool failed to sign the installer (exit code $LASTEXITCODE)."
    }

    Write-Host 'Verifying installer signature...' -ForegroundColor Yellow
    & $SignToolPath verify /pa /all /v $installerPath
    if ($LASTEXITCODE -ne 0) {
        throw "SignTool could not verify the installer signature (exit code $LASTEXITCODE)."
    }
} else {
    Write-Host 'Installer signing skipped (use -Sign to sign it).' -ForegroundColor Yellow
}

$installer = Get-Item -LiteralPath $installerPath
Write-Host "Installer created$(if ($Sign) { ' and signed' }): $($installer.FullName) ($([Math]::Round($installer.Length / 1MB, 2)) MB)" -ForegroundColor Green
return $installer
