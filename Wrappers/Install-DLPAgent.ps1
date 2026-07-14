<#
.SYNOPSIS
    Universal silent-install wrapper for the DLP Agent package (MSI, EXE, or script-based installers).
    Designed to be called as the SCCM Application Deployment Type "Install" command.

.DESCRIPTION
    Wraps msiexec.exe, vendor EXE installers, or custom install scripts behind a single,
    consistent entry point so every DLP Agent deployment type in SCCM behaves the same way:
    same logging location, same exit-code handling, same success/failure semantics.

.PARAMETER InstallerType
    MSI | EXE | Script

.PARAMETER PackagePath
    Full path (or relative path from the SCCM package source) to the installer file.

.PARAMETER Arguments
    Extra arguments passed to the installer. Sensible silent defaults are supplied per type
    if not specified.

.PARAMETER LogDirectory
    Directory where install logs are written. Defaults to C:\Windows\Logs\DLPAgent.

.EXAMPLE
    # SCCM Deployment Type install command line:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-DLPAgent.ps1 `
        -InstallerType MSI -PackagePath ".\DLPAgentSetup.msi"

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-DLPAgent.ps1 `
        -InstallerType EXE -PackagePath ".\DLPAgentSetup.exe" -Arguments "/silent /norestart /log=install.log"

.NOTES
    Exit codes returned to SCCM:
      0    = Success
      3010 = Success, reboot required
      Any other non-zero = Failure (SCCM will mark the deployment type as failed)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('MSI', 'EXE', 'Script')]
    [string]$InstallerType,

    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $false)]
    [string]$Arguments,

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = "$env:WINDIR\Logs\DLPAgent"
)

$ErrorActionPreference = 'Stop'

function Write-InstallLog {
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
    $script:LogFile = Join-Path $LogDirectory "Install-DLPAgent_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    if (-not (Test-Path -Path $PackagePath)) {
        Write-InstallLog "Installer not found at path: $PackagePath" 'ERROR'
        exit 1603
    }

    $resolvedPath = (Resolve-Path -Path $PackagePath).ProviderPath
    Write-InstallLog "Starting DLP Agent install. Type=$InstallerType Path=$resolvedPath"

    switch ($InstallerType) {

        'MSI' {
            $msiLog = Join-Path $LogDirectory "MSI_Install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            $defaultArgs = "/i `"$resolvedPath`" /qn /norestart REBOOT=ReallySuppress /l*v `"$msiLog`""
            $installArgs = if ($Arguments) { $Arguments } else { $defaultArgs }

            Write-InstallLog "Running: msiexec.exe $installArgs"
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -PassThru -WindowStyle Hidden
            $exitCode = $proc.ExitCode
        }

        'EXE' {
            $defaultArgs = "/silent /norestart"
            $installArgs = if ($Arguments) { $Arguments } else { $defaultArgs }

            Write-InstallLog "Running: `"$resolvedPath`" $installArgs"
            $proc = Start-Process -FilePath $resolvedPath -ArgumentList $installArgs -Wait -PassThru -WindowStyle Hidden
            $exitCode = $proc.ExitCode
        }

        'Script' {
            Write-InstallLog "Invoking install script: $resolvedPath $Arguments"
            if ($resolvedPath -match '\.ps1$') {
                $proc = Start-Process -FilePath "powershell.exe" `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$resolvedPath`" $Arguments" `
                    -Wait -PassThru -WindowStyle Hidden
            }
            elseif ($resolvedPath -match '\.(cmd|bat)$') {
                $proc = Start-Process -FilePath $resolvedPath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
            }
            else {
                Write-InstallLog "Unsupported script type: $resolvedPath" 'ERROR'
                exit 1601
            }
            $exitCode = $proc.ExitCode
        }
    }

    Write-InstallLog "Installer process exited with code: $exitCode"

    # Normalise acceptable success codes (0 = success, 3010 = success/reboot required)
    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        Write-InstallLog "DLP Agent install completed successfully (ExitCode=$exitCode)."
        exit $exitCode
    }
    else {
        Write-InstallLog "DLP Agent install FAILED (ExitCode=$exitCode)." 'ERROR'
        exit $exitCode
    }
}
catch {
    Write-InstallLog "Unhandled exception: $($_.Exception.Message)" 'ERROR'
    exit 1
}
