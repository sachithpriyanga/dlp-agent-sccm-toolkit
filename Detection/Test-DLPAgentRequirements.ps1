<#
.SYNOPSIS
    SCCM "script-based requirement rule" for the DLP Agent Deployment Type.

.DESCRIPTION
    Confirms the target machine actually qualifies to receive the DLP Agent before SCCM
    attempts install, so the deployment isn't attempted on unsupported OS builds, low disk
    space, missing prerequisite runtime, or already-conflicting endpoint agents.

    SCCM Requirement rule contract: write "True" to STDOUT (and exit 0) if requirements are
    met; write "False" (or nothing) if not.

.NOTES
    Configure this as a Requirement on the Deployment Type:
      Rule type: Script
      Data type: String
      Script: this file
      Value = "True"  (Equals)
#>

$MinimumFreeDiskGB   = 2
$SupportedBuilds     = @(19041, 19042, 19043, 19044, 19045, 22000, 22621, 22631, 26100) # Win10 20H1+ / Win11
$RequiredDotNetMin   = [version]'4.7.2'
$ConflictingServices = @('McAfeeDLPAgentSvc', 'SymantecDLPAgent') # example conflicting third-party DLP agents

function Get-OsBuildNumber {
    (Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber -as [int]
}

function Test-FreeDiskSpace {
    param([int]$MinimumGB)
    $systemDrive = $env:SystemDrive
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$systemDrive'"
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
    return ($freeGB -ge $MinimumGB)
}

function Test-DotNetVersion {
    param([version]$MinimumVersion)
    try {
        $release = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release
        # Mapping of common release keys to versions (subset covering 4.7.2+)
        return ($release -ge 461808) # 461808 = .NET Framework 4.7.2
    }
    catch {
        return $false
    }
}

function Test-NoConflictingAgent {
    foreach ($svcName in $ConflictingServices) {
        if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
            return $false
        }
    }
    return $true
}

$buildOk       = $SupportedBuilds -contains (Get-OsBuildNumber)
$diskOk        = Test-FreeDiskSpace -MinimumGB $MinimumFreeDiskGB
$dotNetOk      = Test-DotNetVersion -MinimumVersion $RequiredDotNetMin
$noConflictOk  = Test-NoConflictingAgent

if ($buildOk -and $diskOk -and $dotNetOk -and $noConflictOk) {
    Write-Output "True"
}
else {
    Write-Output "False"
}
