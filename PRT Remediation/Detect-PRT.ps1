<#
.SYNOPSIS
    Detects whether the logged-on user has a valid Primary Refresh Token (PRT).
    PRT is a prerequisite for Windows Hello for Business (WHfB).

.DESCRIPTION
    Parses dsregcmd /status to evaluate PRT health on Hybrid AAD / Azure AD Joined devices.
    Checks device join state, PRT presence, and PRT expiry.
    Colour-coded output: green = PASS, red = FAIL, yellow = WARN.

.NOTES
    Intune Remediation — Detection Script
    Run As  : Logged-on user (NOT System)
    Platform: Windows 10/11, Hybrid AAD or Azure AD Joined
    Exit 0  : Compliant  — PRT valid, WHfB prerequisite met
    Exit 1  : Remediate  — PRT missing, expired, or device join broken
#>

$logLines = [System.Collections.Generic.List[string]]::new()

function Write-Detection {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $logLines.Add($line)
    $color = switch ($Level) {
        'PASS'  { 'Green' }
        'FAIL'  { 'Red' }
        'WARN'  { 'Yellow' }
        'INFO'  { 'Cyan' }
        default { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

function Get-DsregValue {
    param([string[]]$Lines, [string]$Key)
    $line = $Lines | Where-Object { $_ -match "^\s+$Key\s*:" } | Select-Object -First 1
    if ($line) { return ($line -split ':', 2)[1].Trim() }
    return $null
}

try {
    Write-Detection "PRT Detection — $env:COMPUTERNAME — User: $env:USERNAME" 'INFO'
    Write-Detection "------------------------------------------------------------" 'INFO'

    $dsreg = & dsregcmd /status 2>&1

    $azureAdJoined = Get-DsregValue -Lines $dsreg -Key 'AzureAdJoined'
    $domainJoined  = Get-DsregValue -Lines $dsreg -Key 'DomainJoined'
    $prtStatus     = Get-DsregValue -Lines $dsreg -Key 'AzureAdPrt'
    $prtExpiry     = Get-DsregValue -Lines $dsreg -Key 'AzureAdPrtExpiryTime'
    $prtUpdate     = Get-DsregValue -Lines $dsreg -Key 'AzureAdPrtUpdateTime'

    # --- Check 1: Azure AD Joined ---
    if ($azureAdJoined -eq 'YES') {
        Write-Detection "CHECK 1 — AzureAdJoined  : YES" 'PASS'
    } else {
        Write-Detection "CHECK 1 — AzureAdJoined  : $azureAdJoined — Hybrid join may be broken" 'FAIL'
        exit 1
    }

    # --- Check 2: Domain Joined ---
    if ($domainJoined -eq 'YES') {
        Write-Detection "CHECK 2 — DomainJoined   : YES" 'PASS'
    } else {
        Write-Detection "CHECK 2 — DomainJoined   : $domainJoined — Device is not domain joined" 'FAIL'
        exit 1
    }

    # --- Check 3: PRT presence ---
    if ($prtStatus -eq 'YES') {
        Write-Detection "CHECK 3 — AzureAdPrt     : YES — PRT present" 'PASS'
    } else {
        Write-Detection "CHECK 3 — AzureAdPrt     : $prtStatus — PRT missing. LastUpdate=$prtUpdate" 'FAIL'
        exit 1
    }

    # --- Check 4: PRT expiry ---
    if ($prtExpiry) {
        try {
            $cleanExpiry = $prtExpiry -replace '\s+UTC$', '' -replace '\s', '-' -replace '(?<=\d{4}-\d{2}-\d{2})-', ' '
            $expiryDate  = [datetime]::Parse($cleanExpiry, [System.Globalization.CultureInfo]::InvariantCulture)
            $now         = (Get-Date).ToUniversalTime()

            if ($expiryDate -le $now) {
                Write-Detection "CHECK 4 — PRT Expiry     : EXPIRED at $prtExpiry" 'FAIL'
                exit 1
            } elseif ($expiryDate -le $now.AddHours(4)) {
                Write-Detection "CHECK 4 — PRT Expiry     : Expiring within 4 hours ($prtExpiry) — proactive refresh needed" 'WARN'
                exit 1
            } else {
                Write-Detection "CHECK 4 — PRT Expiry     : Valid until $prtExpiry" 'PASS'
            }
        } catch {
            Write-Detection "CHECK 4 — PRT Expiry     : Could not parse expiry time — skipping" 'WARN'
        }
    } else {
        Write-Detection "CHECK 4 — PRT Expiry     : No expiry value found" 'WARN'
    }

    Write-Detection "------------------------------------------------------------" 'INFO'
    Write-Detection "RESULT: COMPLIANT — PRT valid, device joined, WHfB prerequisite met" 'PASS'
    exit 0

} catch {
    Write-Detection "ERROR: $($_.Exception.Message)" 'FAIL'
    exit 1
}
