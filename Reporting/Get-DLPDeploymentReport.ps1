<#
.SYNOPSIS
    Pulls real-time DLP Agent deployment/compliance status from SCCM across every site,
    and produces a per-location summary CSV plus an overall rollup on screen.

.DESCRIPTION
    Uses the ConfigurationManager PowerShell module (Microsoft Endpoint Configuration Manager
    console must be installed, or run from a machine with the CM cmdlets available) to pull
    per-device deployment status for the DLP Agent application, then groups results by AD site
    / branch location (via a site-code custom device collection variable, or by resolving the
    device's AD Site if you don't tag collections per branch).

.PARAMETER SiteCode
    Your SCCM site code, e.g. "P01".

.PARAMETER ProviderMachineName
    FQDN of the SCCM site server (SMS Provider).

.PARAMETER ApplicationName
    Exact display name of the DLP Agent application in SCCM (Software Library).

.PARAMETER OutputCsvPath
    Where to write the per-location summary CSV. Defaults to a timestamped file in the
    current directory.

.EXAMPLE
    .\Get-DLPDeploymentReport.ps1 -SiteCode "P01" -ProviderMachineName "sccm01.corp.local" `
        -ApplicationName "DLP Agent 4.2"

.NOTES
    Requires: ConfigurationManager PowerShell module (imported automatically if the console
    is installed at the default path). Run with an account that has SCCM read permissions
    on the application and collections.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SiteCode,

    [Parameter(Mandatory = $true)]
    [string]$ProviderMachineName,

    [Parameter(Mandatory = $true)]
    [string]$ApplicationName,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsvPath = ".\DLPAgent_DeploymentReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

$ErrorActionPreference = 'Stop'

# --- Connect to the SCCM site ---
$cmModulePath = "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
if (-not (Get-Module ConfigurationManager)) {
    if (Test-Path $cmModulePath) {
        Import-Module $cmModulePath
    }
    else {
        throw "ConfigurationManager module not found. Run this from a machine with the SCCM console installed, or adjust `$cmModulePath."
    }
}

if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name $SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root $ProviderMachineName | Out-Null
}
Push-Location "$($SiteCode):\"

try {
    Write-Host "Querying deployment status for '$ApplicationName'..."

    # Pull per-device deployment status for the application across all deployments
    $deployments = Get-CMApplicationDeployment -Name $ApplicationName -ErrorAction SilentlyContinue
    if (-not $deployments) {
        throw "No deployments found for application '$ApplicationName'. Check the name matches exactly."
    }

    $allStatuses = foreach ($dep in $deployments) {
        Get-CMDeploymentStatusDetails -InputObject (Get-CMDeploymentStatus -Name $ApplicationName) -ErrorAction SilentlyContinue
    }

    # Resolve each device's AD Site (used here as the proxy for "branch location")
    $report = foreach ($status in $allStatuses) {
        $device = Get-CMDevice -Name $status.DeviceName -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            DeviceName     = $status.DeviceName
            Location       = if ($device) { $device.ADSiteName } else { "Unknown" }
            ComplianceState = switch ($status.ComplianceState) {
                1 { "Compliant" }
                2 { "NonCompliant" }
                3 { "Conflict" }
                0 { "Unknown" }
                default { "Other ($($status.ComplianceState))" }
            }
            LastStatusTime = $status.LastStatusTime
        }
    }

    # Per-location summary
    $summary = $report |
        Group-Object Location |
        ForEach-Object {
            $total       = $_.Count
            $compliant   = ($_.Group | Where-Object { $_.ComplianceState -eq 'Compliant' }).Count
            $nonCompliant = ($_.Group | Where-Object { $_.ComplianceState -eq 'NonCompliant' }).Count
            [PSCustomObject]@{
                Location        = $_.Name
                TotalDevices    = $total
                Compliant       = $compliant
                NonCompliant    = $nonCompliant
                PercentCompliant = if ($total -gt 0) { [math]::Round(($compliant / $total) * 100, 1) } else { 0 }
            }
        } | Sort-Object Location

    $summary | Export-Csv -Path $OutputCsvPath -NoTypeInformation

    Write-Host ""
    Write-Host "===== DLP Agent Deployment Summary (all locations) ====="
    $summary | Format-Table -AutoSize

    $overallTotal      = ($report | Measure-Object).Count
    $overallCompliant  = ($report | Where-Object { $_.ComplianceState -eq 'Compliant' }).Count
    $overallPercent    = if ($overallTotal -gt 0) { [math]::Round(($overallCompliant / $overallTotal) * 100, 1) } else { 0 }

    Write-Host ""
    Write-Host "Overall: $overallCompliant / $overallTotal devices compliant ($overallPercent%)"
    Write-Host "Per-location CSV written to: $(Resolve-Path $OutputCsvPath)"
}
finally {
    Pop-Location
}
