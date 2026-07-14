DLP Agent — SCCM Packaging & Deployment Toolkit
PowerShell scripts for packaging, deploying, and maintaining a DLP (Data Loss Prevention) agent across a Windows 10/11 fleet using Microsoft Endpoint Configuration Manager (SCCM).
Built to support: consistent silent install/removal regardless of installer type, accurate SCCM compliance detection, pre-flight requirement checks, pre/post-deployment validation, fleet-wide compliance reporting, and low-touch remediation/rollback.
Structure
Wrappers/
  Install-DLPAgent.ps1          # Silent install wrapper (MSI / EXE / script installers)
  Uninstall-DLPAgent.ps1        # Silent removal wrapper (MSI / EXE / script installers)

Detection/
  Detect-DLPAgent.ps1           # SCCM custom detection method (registry + service + file version)
  Test-DLPAgentRequirements.ps1 # SCCM requirement rule (OS build, disk space, .NET, conflicts)

Validation/
  Validate-DLPAgentPackage.ps1  # Pre-deployment (package) and post-deployment (installed state)
                                 # validation: file version, registry keys, service state

Reporting/
  Get-DLPDeploymentReport.ps1   # Pulls live SCCM deployment/compliance status, summarised
                                 # per location, exported to CSV

Remediation/
  Invoke-DLPAgentRemediation.ps1 # Detects unhealthy installs and remediates (service restart
                                 # -> clean uninstall/reinstall -> rollback + flag for follow-up)
Wiring into SCCM
    1. Deployment Type — Install/Uninstall program Set the install/uninstall command line to call the wrapper scripts, e.g.:
       powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-DLPAgent.ps1 -InstallerType MSI -PackagePath ".\DLPAgentSetup.msi"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-DLPAgent.ps1 -InstallerType MSI -ProductCode "{PRODUCT-GUID}"
    2. Detection method Deployment Type → Detection Method → "Use a custom script" → PowerShell → paste in Detect-DLPAgent.ps1 (update the GUID/service/path constants first).
    3. Requirements Deployment Type → Requirements → Add Rule → Custom → Script → Test-DLPAgentRequirements.ps1, condition: String equals True.
    4. Validation (packaging pipeline / QA gate, and post-deploy spot checks)
       .\Validate-DLPAgentPackage.ps1 -Mode PreDeployment -SourcePath "\\sccm-src\Apps\DLPAgent\4.2.0" -ExePath "DlpAgent.exe" -MinimumVersion 4.2.0.0
.\Validate-DLPAgentPackage.ps1 -Mode PostDeployment -ExePath "$env:ProgramFiles\Vendor\DLPAgent\DlpAgent.exe" -ServiceName "DLPAgentService" -RegistryKey "HKLM:\...\Uninstall\{GUID}" -MinimumVersion 4.2.0.0
    5. Reporting — run from a machine with the SCCM console/cmdlets installed:
       .\Get-DLPDeploymentReport.ps1 -SiteCode "P01" -ProviderMachineName "sccm01.corp.local" -ApplicationName "DLP Agent 4.2"
       Produces a per-location (branch/site) CSV plus an overall compliance percentage.
    6. Remediation — wire as a Configuration Item inside a Compliance Baseline:
        ◦ Discovery script: Invoke-DLPAgentRemediation.ps1 -Mode Detect -ServiceName "DLPAgentService"
        ◦ Remediation script: Invoke-DLPAgentRemediation.ps1 -Mode Remediate -ServiceName "DLPAgentService" -ProductCode "{GUID}" -KnownGoodPackagePath "\\sccm-src\...\DLPAgentSetup.msi" Baselines can be scheduled to auto-run and auto-remediate across all collections/sites.
Before using in production
    • Replace all placeholder values ({DLP-AGENT-PRODUCT-GUID}, service name, install paths, minimum version, conflicting-service names) with the actual values for your DLP vendor package.
    • Test the full install → detect → validate → uninstall cycle in a pilot collection before rolling out to production collections.
    • Logs are written to C:\Windows\Logs\DLPAgent\ on each client for troubleshooting.
