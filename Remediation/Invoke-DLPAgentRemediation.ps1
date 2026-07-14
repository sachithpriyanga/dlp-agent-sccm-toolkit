<#
.SYNOPSIS
    Remediation / rollback script for problematic DLP Agent installs.
    Designed to be wired into an SCCM Configuration Item (Compliance Baseline) remediation
    script, or run centrally via SCCM Scripts / Run Script against a target collection.

.DESCRIPTION
    When a machine is found non-compliant (e.g. service crashed, corrupt install, wrong
    version), this script attempts a safe, minimal-touch fix in order of least to most invasive:
      1. Restart the DLP Agent service if it exists but isn't running.
      2. If the service is missing or the install is clearly broken, uninstall cleanly using
         the product code, then reinstall the last known-good version from the package share.
      3. If reinstall also fails, roll back by leaving the machine in "uninstalled" state and
         flagging it for manual follow-up, rather than leaving a half-broken agent in place.

    All actions are logged locally and summarised as a single-line status suitable for
    scraping into a central report.

.PARAMETER Mode
    Detect | Remediate   (Detect = compliance-check only, no changes made; used as the
    "Discovery script" of an SCCM Configuration Item. Remediate = actually fix.)

.PARAMETER KnownGoodPackagePath
    Path to the last known-good installer, used for reinstall.

.PARAMETER ProductCode
    MSI product code of the DLP Agent, used for clean uninstall before reinstall.

.PARAMETER ServiceName
    Name of the DLP Agent Windows service.

.EXAMPLE
    # Compliance baseline discovery
    .\Invoke-DLPAgentRemediation.ps1 -Mode Detect -ServiceName "DLPAgentService"

.EXAMPLE
    # Compliance baseline remediation (runs automatically when Detect returns non-compliant)
    .\Invoke-DLPAgentRemediation.ps1 -Mode Remediate `
        -ServiceName "DLPAgentService" `
        -ProductCode "{A1B2C3D4-E5F6-7890-ABCD-1234567890AB}" `
        -KnownGoodPackagePath "\\sccm-src\Apps\DLPAgent\4.2.0\DLPAgentSetup.msi"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Detect', 'Remediate')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$ServiceName,

    [Parameter(Mandatory = $false)]
    [string]$ProductCode,

    [Parameter(Mandatory = $false)]
    [string]$KnownGoodPackagePath,

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = "$env:WINDIR\Logs\DLPAgent"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}
$logFile = Join-Path $LogDirectory "Remediation_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-RemLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $logFile -Value $line
    Write-Verbose $line
}

function Get-AgentServiceState {
    Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
}

# ---- Detect mode: read-only compliance check, used by SCCM Configuration Item ----
if ($Mode -eq 'Detect') {
    $svc = Get-AgentServiceState
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Output "Compliant"
    }
    else {
        Write-Output "NonCompliant"
    }
    exit 0
}

# ---- Remediate mode ----
Write-RemLog "Remediation started on $env:COMPUTERNAME"
$svc = Get-AgentServiceState

try {
    if ($svc -and $svc.Status -ne 'Running') {
        # Step 1: least invasive fix - try restarting the service
        Write-RemLog "Service '$ServiceName' found but not running (Status=$($svc.Status)). Attempting restart."
        Start-Service -Name $ServiceName -ErrorAction Stop
        Start-Sleep -Seconds 5
        $svc.Refresh()

        if ($svc.Status -eq 'Running') {
            Write-RemLog "Service restarted successfully. Remediation complete (no reinstall needed)."
            Write-Output "Remediated:ServiceRestart"
            exit 0
        }
        Write-RemLog "Service restart did not bring it to Running state. Escalating to reinstall." 'WARN'
    }
    elseif (-not $svc) {
        Write-RemLog "Service '$ServiceName' not found at all. Install appears broken/missing. Escalating to reinstall." 'WARN'
    }
    else {
        Write-RemLog "Service already running; no remediation action required."
        Write-Output "Compliant:NoActionNeeded"
        exit 0
    }

    # Step 2: clean uninstall + reinstall from known-good package
    if (-not $ProductCode -or -not $KnownGoodPackagePath) {
        Write-RemLog "ProductCode / KnownGoodPackagePath not supplied - cannot attempt reinstall. Flagging for manual follow-up." 'ERROR'
        Write-Output "RemediationFailed:MissingParameters"
        exit 1
    }

    if (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode") {
        Write-RemLog "Uninstalling existing (broken) install via product code $ProductCode"
        $uninstallProc = Start-Process -FilePath "msiexec.exe" `
            -ArgumentList "/x $ProductCode /qn /norestart" -Wait -PassThru -WindowStyle Hidden
        Write-RemLog "Uninstall exit code: $($uninstallProc.ExitCode)"
    }
    else {
        Write-RemLog "No existing MSI registration found for $ProductCode; proceeding straight to reinstall."
    }

    if (-not (Test-Path -Path $KnownGoodPackagePath)) {
        Write-RemLog "Known-good package not reachable at $KnownGoodPackagePath. Rolling back: leaving machine uninstalled and flagging for manual follow-up." 'ERROR'
        Write-Output "RolledBack:PackageUnreachable"
        exit 1
    }

    Write-RemLog "Reinstalling from known-good package: $KnownGoodPackagePath"
    $installProc = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList "/i `"$KnownGoodPackagePath`" /qn /norestart" -Wait -PassThru -WindowStyle Hidden
    Write-RemLog "Reinstall exit code: $($installProc.ExitCode)"

    Start-Sleep -Seconds 10
    $svcAfter = Get-AgentServiceState
    if ($svcAfter -and $svcAfter.Status -eq 'Running') {
        Write-RemLog "Reinstall successful. Service is running."
        Write-Output "Remediated:Reinstall"
        exit 0
    }
    else {
        Write-RemLog "Reinstall completed but service still not healthy. Rolling back / flagging for manual intervention." 'ERROR'
        Write-Output "RolledBack:ReinstallDidNotFixService"
        exit 1
    }
}
catch {
    Write-RemLog "Unhandled exception during remediation: $($_.Exception.Message)" 'ERROR'
    Write-Output "RemediationFailed:Exception"
    exit 1
}
