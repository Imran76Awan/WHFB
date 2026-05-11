<#
.SYNOPSIS
    Intune Proactive Remediation — Detection script.
    Exits 0 (compliant) if WHfB is enrolled; exits 1 (non-compliant) if not.
#>

$raw    = & dsregcmd /status 2>&1
$ngcSet = $raw | Select-String 'NgcSet\s*:\s*YES'
$prt    = $raw | Select-String 'AzureAdPrt\s*:\s*YES'

if ($ngcSet) {
    Write-Output "COMPLIANT: NgcSet = YES"
    exit 0
} elseif ($prt) {
    Write-Output "NON-COMPLIANT: PRT present but NgcSet = NO"
    exit 1
} else {
    Write-Output "NON-COMPLIANT: No PRT - device not registered"
    exit 1
}
