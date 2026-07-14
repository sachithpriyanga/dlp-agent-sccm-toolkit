<#
.SYNOPSIS
    Universal silent-uninstall wrapper for the DLP Agent package (MSI, EXE, or script-based installers).
    Designed to be called as the SCCM Application Deployment Type "Uninstall" command.

.PARAMETER InstallerType
    MSI | EXE | Script

.PARAMETER ProductCode
    MSI GUID product code (used when InstallerType = MSI). Preferred over pointing at the
    original .msi, since the source file may not be present on the client at uninstall time.

.PARAMETER UninstallPath
    Path to the EXE uninstaller (or its uninstall string) or the removal script.

.PARAMETER Arguments
    Extra arguments for the uninstaller. Sensible silent defaults are supplied if not specified.

.PARAMETER LogDirectory
    Directory where uninstall logs are written. Defaults to C:\Windows\Logs\DLPAgent.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-DLPAgent.ps1 `
        -InstallerType MSI -ProductCode "{A1B2C3D4-E5F6-7890-ABCD-1234567890AB}"

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-DLPAgent.ps1 `
        -InstallerType EXE -UninstallPath "C:\Program Files\Vendor\DLPAgent\uninstall.exe" -Arguments "/silent"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('MSI', 'EXE', 'Script')]
    [string]$InstallerType,

    [Parameter(Mandatory = $false)]
    [string]$ProductCode,

    [Parameter(Mandatory = $false)]
    [string]$UninstallPath,

    [Parameter(Mandatory = $false)]
    [string]$Arguments,

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = "$env:WINDIR\Logs\DLPAgent"
)

$ErrorActionPreference = 'Stop'

function Write-UninstallLog {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $line
    Write-Verbose $line
}

try {
    if (-not (Test-Path -Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }
    $script:LogFile = Join-Path $LogDirectory "Uninstall-DLPAgent_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    Write-UninstallLog "Starting DLP Agent uninstall. Type=$InstallerType"

    switch ($InstallerType) {

        'MSI' {
            if (-not $ProductCode) {
                Write-UninstallLog "ProductCode is required when InstallerType=MSI" 'ERROR'
                exit 1603
            }
            $msiLog = Join-Path $LogDirectory "MSI_Uninstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            $defaultArgs = "/x $ProductCode /qn /norestart /l*v `"$msiLog`""
            $uninstallArgs = if ($Arguments) { $Arguments } else { $defaultArgs }

            Write-UninstallLog "Running: msiexec.exe $uninstallArgs"
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $uninstallArgs -Wait -PassThru -WindowStyle Hidden
            $exitCode = $proc.ExitCode
        }

        'EXE' {
            if (-not $UninstallPath -or -not (Test-Path -Path $UninstallPath)) {
                Write-UninstallLog "Uninstaller not found at: $UninstallPath" 'ERROR'
                exit 1603
            }
            $defaultArgs = "/silent /uninstall"
            $uninstallArgs = if ($Arguments) { $Arguments } else { $defaultArgs }

            Write-UninstallLog "Running: `"$UninstallPath`" $uninstallArgs"
            $proc = Start-Process -FilePath $UninstallPath -ArgumentList $uninstallArgs -Wait -PassThru -WindowStyle Hidden
            $exitCode = $proc.ExitCode
        }

        'Script' {
            if (-not $UninstallPath -or -not (Test-Path -Path $UninstallPath)) {
                Write-UninstallLog "Removal script not found at: $UninstallPath" 'ERROR'
                exit 1601
            }
            Write-UninstallLog "Invoking removal script: $UninstallPath $Arguments"
            $proc = Start-Process -FilePath "powershell.exe" `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$UninstallPath`" $Arguments" `
                -Wait -PassThru -WindowStyle Hidden
            $exitCode = $proc.ExitCode
        }
    }

    Write-UninstallLog "Uninstaller process exited with code: $exitCode"

    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        Write-UninstallLog "DLP Agent uninstall completed successfully (ExitCode=$exitCode)."
        exit $exitCode
    }
    else {
        Write-UninstallLog "DLP Agent uninstall FAILED (ExitCode=$exitCode)." 'ERROR'
        exit $exitCode
    }
}
catch {
    Write-UninstallLog "Unhandled exception: $($_.Exception.Message)" 'ERROR'
    exit 1
}
