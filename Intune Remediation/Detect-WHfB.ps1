#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Detection Script - Windows Hello for Business (WHfB) Health Check

.DESCRIPTION
    Checks whether WHfB is fully provisioned and healthy on this device.
    Designed for use as an Intune Proactive Remediation detection script.

    Exit codes:
      0 = Compliant   (WHfB healthy - no remediation needed)
      1 = Non-compliant (remediation script will run)

.NOTES
    Run context : Can run as SYSTEM or logged-on user.
                  PRT and NGC checks are more accurate in user context.
    Schedule    : Recommended - every 1 hour or daily
#>

$ErrorActionPreference = 'SilentlyContinue'

#region -- Logging (lightweight - stdout only for Intune) ----------------------

$logLines = [System.Collections.Generic.List[string]]::new()

function Write-Detection {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $logLines.Add($line)
    $color = switch ($Level) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

#endregion

#region -- dsregcmd parser -----------------------------------------------------

function Get-DsregStatus {
    $raw = & dsregcmd.exe /status 2>&1
    $map = @{}
    foreach ($line in $raw) {
        if ($line -match '^\s+([A-Za-z0-9_]+)\s*:\s*(.+)$') {
            $map[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $map
}

#endregion

#region -- Checks --------------------------------------------------------------

$failures = [System.Collections.Generic.List[string]]::new()
$dsreg    = Get-DsregStatus

Write-Detection "Device: $env:COMPUTERNAME | User: $env:USERNAME"
Write-Detection "dsregcmd parsed $($dsreg.Count) values"

# ── Check 1: Azure AD Join ────────────────────────────────────────────────────
$aadJoined    = $dsreg['AzureAdJoined'] -eq 'YES'
$domainJoined = $dsreg['DomainJoined']  -eq 'YES'
$deviceId     = $dsreg['DeviceId']

if ($aadJoined -and $domainJoined) {
    Write-Detection "Join status   : Hybrid Azure AD Joined [$deviceId]" 'PASS'
}
elseif ($aadJoined) {
    Write-Detection "Join status   : Azure AD Joined [$deviceId]" 'PASS'
}
else {
    Write-Detection "Join status   : NOT Azure AD Joined - WHfB requires AAD or Hybrid join" 'FAIL'
    $failures.Add('Device not Azure AD Joined')
}

# ── Check 2: Primary Refresh Token -------------------------------------------
$prt        = $dsreg['AzureAdPrt']
$prtUpdated = $dsreg['AzureAdPrtUpdateTime']

if ($prt -eq 'YES') {
    Write-Detection "PRT           : Present (updated: $prtUpdated)" 'PASS'
}
else {
    Write-Detection "PRT           : MISSING - user cannot authenticate to Azure AD" 'FAIL'
    $failures.Add('Primary Refresh Token missing or invalid')
}

# ── Check 3: WHfB NGC Key Provisioning ---------------------------------------
$ngcSet   = $dsreg['NgcSet']
$ngcKeyId = $dsreg['NgcKeyId']

if ($ngcSet -eq 'YES' -and -not [string]::IsNullOrWhiteSpace($ngcKeyId) -and $ngcKeyId -ne 'ERROR') {
    Write-Detection "NGC/WHfB key  : Provisioned [KeyId: $ngcKeyId]" 'PASS'
}
elseif ($ngcSet -eq 'YES') {
    Write-Detection "NGC/WHfB key  : NgcSet=YES but KeyId missing - possible corruption" 'FAIL'
    $failures.Add('WHfB NGC key ID missing or corrupted')
}
else {
    Write-Detection "NGC/WHfB key  : NOT provisioned - WHfB enrollment not completed" 'FAIL'
    $failures.Add('WHfB NGC key not provisioned (NgcSet = NO)')
}

# ── Check 4: TPM Health -------------------------------------------------------
try {
    $tpm = Get-Tpm -ErrorAction Stop

    if (-not $tpm.TpmPresent) {
        Write-Detection "TPM           : NOT present" 'FAIL'
        $failures.Add('TPM not detected')
    }
    elseif (-not $tpm.TpmEnabled) {
        Write-Detection "TPM           : Present but DISABLED in firmware" 'FAIL'
        $failures.Add('TPM disabled in BIOS/UEFI')
    }
    elseif (-not $tpm.TpmReady) {
        Write-Detection "TPM           : Present and enabled but NOT READY (ownership/provisioning broken)" 'FAIL'
        $failures.Add('TPM not ready - ownership or provisioning issue')
    }
    else {
        Write-Detection "TPM           : Present, enabled and ready (Owned: $($tpm.TpmOwned))" 'PASS'
    }

    # Check TPM version via CIM
    try {
        $tpmCim = Get-CimInstance -Namespace 'root/cimv2/security/microsofttpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
        $specVer = $tpmCim.SpecVersion
        if ($specVer -notmatch '^2\.') {
            Write-Detection "TPM version   : $specVer - WHfB strongly recommends TPM 2.0" 'WARN'
        }
        else {
            Write-Detection "TPM version   : $specVer" 'PASS'
        }
    }
    catch {
        Write-Detection "TPM version   : Could not read spec version" 'WARN'
    }
}
catch {
    Write-Detection "TPM           : Get-Tpm failed - $_" 'FAIL'
    $failures.Add("TPM check error: $_")
}

# ── Check 5: Required Services -----------------------------------------------
$criticalServices = @('KeyIso', 'NgcSvc', 'NgcCtnrSvc', 'TokenBroker')
foreach ($svcName in $criticalServices) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Detection "Service [$svcName]  : Running" 'PASS'
    }
    elseif ($svc) {
        Write-Detection "Service [$svcName]  : $($svc.Status) - required for WHfB" 'FAIL'
        $failures.Add("Required service $svcName is $($svc.Status)")
    }
    else {
        Write-Detection "Service [$svcName]  : Not found" 'WARN'
    }
}

# ── Check 6: WHfB Policy in Registry -----------------------------------------
$policyPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork',
    'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork',
    'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\PassportForWork'
)

$policyFound = $false
$policyDisabled = $false

foreach ($path in $policyPaths) {
    if (Test-Path $path) {
        $policyFound = $true
        $pol = Get-ItemProperty $path -ErrorAction SilentlyContinue
        if ($pol.Enabled -eq 0) {
            $policyDisabled = $true
        }
    }
}

if ($policyDisabled) {
    Write-Detection "WHfB Policy   : DISABLED by registry policy" 'FAIL'
    $failures.Add('WHfB disabled by registry/GPO policy (Enabled = 0)')
}
elseif ($policyFound) {
    Write-Detection "WHfB Policy   : Policy key present in registry" 'PASS'
}
else {
    Write-Detection "WHfB Policy   : No policy key found (using Windows defaults - WHfB allowed)" 'PASS'
}

#endregion

#region -- Result --------------------------------------------------------------

Write-Detection "--- RESULT ---"

if ($failures.Count -eq 0) {
    Write-Detection "COMPLIANT - WHfB is fully provisioned and healthy" 'PASS'
    Write-Detection "Checks: Join=OK, PRT=OK, NGC=OK, TPM=OK, Services=OK, Policy=OK"
    exit 0
}
else {
    Write-Detection "NON-COMPLIANT - $($failures.Count) issue(s) found:" 'FAIL'
    foreach ($f in $failures) {
        Write-Detection "  >> $f" 'FAIL'
    }
    exit 1
}

#endregion
