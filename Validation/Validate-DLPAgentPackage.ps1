<#
.SYNOPSIS
    Validates a DLP Agent package/install against expected file version, registry keys,
    and service state — before packaging sign-off, and again after deployment to confirm success.

.DESCRIPTION
    Run in two modes:
      -Mode PreDeployment  : validates the installer source files in the SCCM package share
                              (staging folder) before the package is promoted to production.
      -Mode PostDeployment : validates the installed state on a target machine after the
                              SCCM deployment has run (used standalone, or wired into a
                              Configuration Baseline / compliance check).

    Emits a structured PSCustomObject report plus a human-readable PASS/FAIL summary, and
    exits non-zero if any check fails — so it can be chained in a CI/packaging pipeline.

.PARAMETER Mode
    PreDeployment | PostDeployment

.PARAMETER SourcePath
    (PreDeployment) Path to the package source folder containing the installer / binaries.

.PARAMETER ExePath
    (PostDeployment) Installed path of the DLP agent's main executable.

.PARAMETER MinimumVersion
    Minimum acceptable file version.

.PARAMETER ServiceName
    Expected Windows service name (PostDeployment only).

.PARAMETER RegistryKey
    Expected uninstall/registry key (PostDeployment only).

.PARAMETER ReportPath
    Optional path to write the JSON validation report. Defaults to a timestamped file
    under C:\Windows\Logs\DLPAgent (created if missing).

.EXAMPLE
    .\Validate-DLPAgentPackage.ps1 -Mode PreDeployment -SourcePath "\\sccm-src\Apps\DLPAgent\4.2.0" `
        -ExePath "DlpAgent.exe" -MinimumVersion 4.2.0.0

.EXAMPLE
    .\Validate-DLPAgentPackage.ps1 -Mode PostDeployment `
        -ExePath "$env:ProgramFiles\Vendor\DLPAgent\DlpAgent.exe" `
        -ServiceName "DLPAgentService" `
        -RegistryKey "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{DLP-AGENT-PRODUCT-GUID}" `
        -MinimumVersion 4.2.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('PreDeployment', 'PostDeployment')]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [Parameter(Mandatory = $true)]
    [version]$MinimumVersion,

    [Parameter(Mandatory = $false)]
    [string]$ServiceName,

    [Parameter(Mandatory = $false)]
    [string]$RegistryKey,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath = "$env:WINDIR\Logs\DLPAgent\Validation_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
)

$results = [ordered]@{
    Mode           = $Mode
    ComputerName   = $env:COMPUTERNAME
    Timestamp      = (Get-Date).ToString("s")
    Checks         = @()
    OverallPass    = $true
}

function Add-Check {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $script:results.Checks += [ordered]@{ Name = $Name; Pass = $Pass; Detail = $Detail }
    if (-not $Pass) { $script:results.OverallPass = $false }
    $status = if ($Pass) { 'PASS' } else { 'FAIL' }
    Write-Host "[$status] $Name - $Detail"
}

# Resolve the file to check depending on mode
$fileToCheck = if ($Mode -eq 'PreDeployment') {
    if (-not $SourcePath) { throw "SourcePath is required for PreDeployment mode." }
    Join-Path $SourcePath $ExePath
}
else {
    $ExePath
}

# 1. File version check
if (Test-Path -Path $fileToCheck) {
    try {
        $fileVersion = [version](Get-Item -Path $fileToCheck).VersionInfo.FileVersion
        $versionOk = $fileVersion -ge $MinimumVersion
        Add-Check -Name "FileVersion" -Pass $versionOk -Detail "Found $fileVersion, required >= $MinimumVersion"
    }
    catch {
        Add-Check -Name "FileVersion" -Pass $false -Detail "Could not read version info: $($_.Exception.Message)"
    }
}
else {
    Add-Check -Name "FileVersion" -Pass $false -Detail "File not found at $fileToCheck"
}

# 2 & 3. Registry + Service checks only apply post-deployment (installed machine state)
if ($Mode -eq 'PostDeployment') {

    if ($RegistryKey) {
        if (Test-Path -Path $RegistryKey) {
            $props = Get-ItemProperty -Path $RegistryKey -ErrorAction SilentlyContinue
            Add-Check -Name "RegistryKey" -Pass $true -Detail "Key present. DisplayVersion=$($props.DisplayVersion)"
        }
        else {
            Add-Check -Name "RegistryKey" -Pass $false -Detail "Expected key not found: $RegistryKey"
        }
    }

    if ($ServiceName) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) {
            $healthy = ($svc.Status -eq 'Running')
            Add-Check -Name "Service" -Pass $healthy -Detail "Status=$($svc.Status) StartType=$($svc.StartType)"
        }
        else {
            Add-Check -Name "Service" -Pass $false -Detail "Service '$ServiceName' not found"
        }
    }
}

# Write JSON report
$reportDir = Split-Path -Path $ReportPath -Parent
if (-not (Test-Path -Path $reportDir)) {
    New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
}
$results | ConvertTo-Json -Depth 4 | Out-File -FilePath $ReportPath -Encoding utf8

Write-Host ""
Write-Host "Validation report written to: $ReportPath"
Write-Host "Overall result: $(if ($results.OverallPass) {'PASS'} else {'FAIL'})"

if (-not $results.OverallPass) { exit 1 } else { exit 0 }
