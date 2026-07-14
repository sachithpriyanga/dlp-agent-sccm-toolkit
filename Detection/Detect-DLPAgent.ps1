<#
.SYNOPSIS
    SCCM custom detection method (script) for the DLP Agent.

.DESCRIPTION
    Used as the "Use a custom detection script" option on the SCCM Application Deployment Type.
    SCCM's rule: if the script writes ANY string to STDOUT and exits 0, the app is considered
    "Installed / Compliant". Silence (no STDOUT) or a non-zero exit means "Not detected".

    Checks three independent signals so a partially-broken install is correctly reported
    as non-compliant rather than a false positive:
      1. Registry uninstall key exists with the expected version (or higher)
      2. The agent's Windows service exists and is set to Automatic / Running
      3. The core binary on disk is present and its file version meets the minimum

.NOTES
    Adjust $RegistryUninstallKey, $ServiceName, $ExePath, and $MinimumVersion for the
    actual DLP vendor package before deploying.
#>

# ---- Configuration: adjust these for your DLP agent package ----
$RegistryUninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{DLP-AGENT-PRODUCT-GUID}',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{DLP-AGENT-PRODUCT-GUID}'
)
$ServiceName    = 'DLPAgentService'
$ExePath        = "$env:ProgramFiles\Vendor\DLPAgent\DlpAgent.exe"
$MinimumVersion = [version]'4.2.0.0'
# ------------------------------------------------------------------

function Test-RegistryInstall {
    foreach ($key in $RegistryUninstallKeys) {
        if (Test-Path -Path $key) {
            $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if ($props -and $props.DisplayVersion) {
                try {
                    if ([version]$props.DisplayVersion -ge $MinimumVersion) {
                        return $true
                    }
                }
                catch {
                    # DisplayVersion wasn't a parseable version string; presence alone still counts
                    return $true
                }
            }
        }
    }
    return $false
}

function Test-ServiceHealthy {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    return ($svc.StartType -in @('Automatic', 'AutomaticDelayedStart') -and $svc.Status -eq 'Running')
}

function Test-BinaryVersion {
    if (-not (Test-Path -Path $ExePath)) { return $false }
    try {
        $fileVersion = (Get-Item -Path $ExePath).VersionInfo.FileVersion
        return ([version]$fileVersion -ge $MinimumVersion)
    }
    catch {
        return $false
    }
}

$registryOk = Test-RegistryInstall
$serviceOk  = Test-ServiceHealthy
$binaryOk   = Test-BinaryVersion

if ($registryOk -and $serviceOk -and $binaryOk) {
    Write-Output "Installed"
    exit 0
}
else {
    # No output, exit 0 => SCCM reports "Not Detected" (not installed / non-compliant)
    exit 0
}
